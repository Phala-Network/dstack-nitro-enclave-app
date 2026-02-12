#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c5.xlarge}"
KEY_NAME="${KEY_NAME:-nitro-enclave-key}"
KEY_PATH="${KEY_PATH:-$PWD/nitro-enclave-key.pem}"
INSTANCE_NAME="${INSTANCE_NAME:-nitro-enclave-host}"
EBS_SIZE_GB="${EBS_SIZE_GB:-20}"
ENCLAVE_CID="${ENCLAVE_CID:-16}"
ENCLAVE_CPU="${ENCLAVE_CPU:-2}"
ENCLAVE_MEM="${ENCLAVE_MEM:-512}"

export AWS_PAGER=""

echo "[1/12] Discover default VPC/subnet/sg"
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)

echo "[2/12] Ensure key pair"
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  if [ ! -f "$KEY_PATH" ]; then
    echo "Key pair exists but $KEY_PATH not found. Aborting."
    exit 1
  fi
else
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$KEY_PATH"
  chmod 400 "$KEY_PATH"
fi

echo "[3/12] Allow SSH from current IP"
MYIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MYIP}/32" >/dev/null 2>&1 || true

echo "[4/12] Find Ubuntu 22.04 AMI"
AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters Name=name,Values='ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' Name=state,Values=available \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

echo "[5/12] Launch EC2 instance"
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "[6/12] Enable enclave options (stop/modify/start)"
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$INSTANCE_ID" \
  --attribute enclaveOptions --value true
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
cat >deployment.json <<EOF
{
  "instance_id": "$INSTANCE_ID",
  "public_ip": "$PUBLIC_IP"
}
EOF

echo "[7/12] Expand root volume to ${EBS_SIZE_GB}GB"
VOLUME_ID=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
aws ec2 modify-volume --region "$REGION" --volume-id "$VOLUME_ID" --size "$EBS_SIZE_GB" >/dev/null

echo "[8/12] SSH to instance: $PUBLIC_IP"
SSH="ssh -o StrictHostKeyChecking=no -i $KEY_PATH ubuntu@$PUBLIC_IP"

$SSH <<'EOF'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y build-essential "linux-modules-extra-$(uname -r)" git docker.io cloud-guest-utils
sudo systemctl enable --now docker

# Grow disk (ignore errors if already grown)
sudo growpart /dev/nvme0n1 1 || true
sudo resize2fs /dev/nvme0n1p1 || true

sudo modprobe nitro_enclaves

if [ ! -d /home/ubuntu/aws-nitro-enclaves-cli ]; then
  git clone https://github.com/aws/aws-nitro-enclaves-cli.git /home/ubuntu/aws-nitro-enclaves-cli
fi

# Patch scripts to avoid rebuilding/inserting driver from sources
python3 - <<'PY'
from pathlib import Path
import re

cfg = Path('/home/ubuntu/aws-nitro-enclaves-cli/bootstrap/nitro-cli-config')
text = cfg.read_text()
pattern = r"\n    # Remove an older driver.*?\n\n    print \"Configuring the device file...\""
new = re.sub(pattern, "\n\n    print \"Configuring the device file...\"", text, flags=re.S)
cfg.write_text(new)

env = Path('/home/ubuntu/aws-nitro-enclaves-cli/bootstrap/env.sh')
lines = env.read_text().splitlines()
filtered = []
for line in lines:
    if 'lsmod | grep -q nitro_enclaves' in line:
        continue
    if 'nitro_enclaves.ko' in line and 'sudo insmod' in line:
        continue
    filtered.append(line)
env.write_text('\n'.join(filtered) + '\n')

mk = Path('/home/ubuntu/aws-nitro-enclaves-cli/Makefile')
lines = mk.read_text().splitlines()
new_lines = []
for line in lines:
    if line.startswith('install: install-tools nitro_enclaves'):
        new_lines.append('install: install-tools')
        continue
    if 'extra/nitro_enclaves' in line or 'nitro_enclaves.ko' in line:
        continue
    new_lines.append(line)
mk.write_text('\n'.join(new_lines) + '\n')
PY

cd /home/ubuntu/aws-nitro-enclaves-cli
sudo bash -lc "cd /home/ubuntu/aws-nitro-enclaves-cli && make nitro-cli"
sudo bash -lc "cd /home/ubuntu/aws-nitro-enclaves-cli && make vsock-proxy"
sudo bash -lc "cd /home/ubuntu/aws-nitro-enclaves-cli && make NITRO_CLI_INSTALL_DIR=/ install"

sudo -u ubuntu -H bash -lc "source /etc/profile.d/nitro-cli-env.sh && cd /home/ubuntu/aws-nitro-enclaves-cli && nitro-cli-config -i"
sudo systemctl enable --now nitro-enclaves-allocator.service

# Build command-executer EIF (vsock demo)
sudo bash -lc "cd /home/ubuntu/aws-nitro-enclaves-cli && make command-executer"

# Run enclave
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli run-enclave \
  --cpu-count ${ENCLAVE_CPU} --memory ${ENCLAVE_MEM} --enclave-cid ${ENCLAVE_CID} \
  --eif-path /home/ubuntu/aws-nitro-enclaves-cli/build/command-executer/command_executer.eif \
  --debug-mode"

# VSock demo: run a command inside enclave
/home/ubuntu/aws-nitro-enclaves-cli/build/command-executer/release/command-executer \
  run --cid ${ENCLAVE_CID} --port 5005 --command "whoami"
EOF

echo
echo "Done. Instance: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
