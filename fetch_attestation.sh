#!/usr/bin/env bash
# One-click: build local dstack-util (musl), push to host, rebuild EIF, fetch attestation.bin (production PCRs)
# Usage:
#   HOST=3.227.1.201 ./fetch_attestation.sh
# Optional env:
#   KEY_PATH      path to SSH key (default: $PWD/nitro-enclave-key.pem)
#   REMOTE_HEX    remote hex path (default: /tmp/attestation_prod.hex)
#   REMOTE_EIF    remote EIF path (default: /home/ubuntu/dstack-attest-py.eif)
#   REMOTE_BIN    remote dstack-util path (default: /home/ubuntu/dstack-util)
# Output:
#   Saves binary attestation to nitro_attestation.bin
set -euo pipefail

HOST=${HOST:-${1:-}}
KEY_PATH=${KEY_PATH:-"$PWD/nitro-enclave-key.pem"}
REMOTE_HEX=${REMOTE_HEX:-/tmp/attestation_prod.hex}
REMOTE_EIF=${REMOTE_EIF:-/home/ubuntu/dstack-attest-py.eif}
REMOTE_BIN=${REMOTE_BIN:-/home/ubuntu/dstack-util}
LOCAL_HEX=${LOCAL_HEX:-/tmp/attestation_prod.hex}
LOCAL_BIN=${LOCAL_BIN:-"$(pwd)/nitro_attestation.bin"}

if [[ -z "${HOST}" && ! -f deployment.json ]]; then
  echo "Usage: HOST=<public_ip> ./fetch_attestation.sh" >&2
  exit 1
fi
HOST=${HOST:-$(jq -r .public_ip < deployment.json)}

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "SSH key not found: ${KEY_PATH}" >&2
  exit 1
fi

SSH_OPTS=("-o" "StrictHostKeyChecking=no" "-i" "${KEY_PATH}")

# Build local dstack-util (musl)
echo "[local] Building dstack-util (musl)..."
cd "$(dirname "$0")/dstack"
cargo build --release -p dstack-util --target x86_64-unknown-linux-musl >/dev/null
LOCAL_DSTACK="$(pwd)/target/x86_64-unknown-linux-musl/release/dstack-util"
echo "[local] Built ${LOCAL_DSTACK}"

# Copy binary to host
echo "[local] Uploading dstack-util to host..."
scp "${SSH_OPTS[@]}" "${LOCAL_DSTACK}" "ubuntu@${HOST}:${REMOTE_BIN}" >/dev/null

ssh "${SSH_OPTS[@]}" "ubuntu@${HOST}" bash -se <<EOF
set -euo pipefail

# Ensure ncat is available
if ! command -v ncat >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y ncat >/dev/null
fi

# Build EIF from uploaded binary
cat > /home/ubuntu/run_attest_py.sh << "EOS"
#!/bin/sh
set -eu
ATTESTATION=\$(/app/dstack-util attest --app-id "e3b0c44298fc1c149afbf4c8996fb92427ae41e4" --report-data "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" --hex 2>/tmp/attest_err || true)
if [ -n "\${ATTESTATION}" ]; then
  echo "\${ATTESTATION}" | socat -t 10 STDIN VSOCK-CONNECT:3:9999
elif [ -s /tmp/attest_err ]; then
  printf "ERROR: %s\n" "\$(cat /tmp/attest_err)" | socat -t 10 STDIN VSOCK-CONNECT:3:9999
else
  echo "ERROR: attestation empty" | socat -t 10 STDIN VSOCK-CONNECT:3:9999
fi
EOS
chmod +x /home/ubuntu/run_attest_py.sh

cat > /home/ubuntu/Dockerfile.attest_py << "EOS"
FROM public.ecr.aws/docker/library/alpine:3.19
RUN apk add --no-cache socat
COPY dstack-util /app/dstack-util
RUN chmod +x /app/dstack-util
COPY run_attest_py.sh /app/run.sh
RUN chmod +x /app/run.sh
ENTRYPOINT ["/app/run.sh"]
EOS

cd /home/ubuntu
sudo docker build -t dstack-attest-py -f Dockerfile.attest_py . >/dev/null
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli build-enclave --docker-uri dstack-attest-py --output-file ${REMOTE_EIF}" >/dev/null

# Ensure allocator has enough CPUs for enclave
sudo bash -lc "if [ -f /etc/nitro_enclaves/allocator.yaml ]; then \
  sudo sed -i 's/^cpu_count:.*/cpu_count: 2/' /etc/nitro_enclaves/allocator.yaml; \
  sudo systemctl enable --now nitro-enclaves-allocator.service >/dev/null; \
fi"

# Clean up old enclave and listener
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli terminate-enclave --all 2>/dev/null || true"
sudo rm -f ${REMOTE_HEX}

# Start vsock listener (host side) to capture attestation
sudo ncat --vsock -l 9999 > ${REMOTE_HEX} 2>/dev/null &
NCAT_PID=\$!
sleep 2

# Run enclave in production mode (no debug/console)
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli run-enclave --cpu-count 2 --memory 256 --enclave-cid 16 --eif-path ${REMOTE_EIF}"

# Wait for enclave to finish and data to be written
sleep 15

# Stop listener and fix permissions
sudo kill \${NCAT_PID} 2>/dev/null || true
sudo chown ubuntu:ubuntu ${REMOTE_HEX} || true
ls -l ${REMOTE_HEX}
EOF

# Copy the hex file back
scp "${SSH_OPTS[@]}" "ubuntu@${HOST}:${REMOTE_HEX}" "${LOCAL_HEX}" >/dev/null

# Convert hex to binary attestation
if [[ ! -s "${LOCAL_HEX}" ]] || ! rg -q "^[0-9a-fA-F]+$" "${LOCAL_HEX}"; then
  echo "Attestation fetch failed; response:" >&2
  cat "${LOCAL_HEX}" >&2 || true
  exit 1
fi

mkdir -p "$(dirname "${LOCAL_BIN}")"
xxd -r -p "${LOCAL_HEX}" > "${LOCAL_BIN}"

echo "Saved attestation to ${LOCAL_BIN} (size: $(stat -c%s "${LOCAL_BIN}") bytes)"
