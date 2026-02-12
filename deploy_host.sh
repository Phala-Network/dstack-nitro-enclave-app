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

echo "[1/8] Discover default VPC/subnet/sg"
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)

echo "[2/8] Ensure key pair"
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

echo "[3/8] Allow SSH from current IP"
MYIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MYIP}/32" >/dev/null 2>&1 || true

echo "[4/8] Find Amazon Linux 2023 AMI"
AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners amazon \
  --filters Name=name,Values='al2023-ami-2023.*-x86_64' Name=state,Values=available \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

echo "[5/8] Launch EC2 instance (with enclave support)"
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --enclave-options Enabled=true \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${EBS_SIZE_GB}}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
cat >deployment.json <<EOF
{
  "instance_id": "$INSTANCE_ID",
  "public_ip": "$PUBLIC_IP"
}
EOF

echo "[6/8] SSH to instance: $PUBLIC_IP"
SSH="ssh -o StrictHostKeyChecking=no -i $KEY_PATH ec2-user@$PUBLIC_IP"

$SSH <<'EOF'
set -euo pipefail

sudo dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel docker
sudo systemctl enable --now docker nitro-enclaves-allocator.service
sudo usermod -aG docker,ne ec2-user

echo "Nitro Enclaves environment ready."
nitro-cli --version
EOF

echo
echo "Done. Instance: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
