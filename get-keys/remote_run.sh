#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_EIF="${REMOTE_EIF:?REMOTE_EIF is required}"
REMOTE_JSON="${REMOTE_JSON:?REMOTE_JSON is required}"

# Ensure ncat, jq, socat, and tinyproxy are available
if ! command -v ncat >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1 || ! command -v tinyproxy >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y ncat jq socat tinyproxy >/dev/null
fi

# Build EIF from uploaded binary
chmod +x "${SCRIPT_DIR}/enclave_run_get_keys.sh"
cp -f /home/ubuntu/dstack-util "${SCRIPT_DIR}/dstack-util"

sudo docker build -t dstack-get-keys -f "${SCRIPT_DIR}/Dockerfile.get_keys" "${SCRIPT_DIR}" >/dev/null
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli build-enclave --docker-uri dstack-get-keys --output-file ${REMOTE_EIF}" >/dev/null

# Ensure allocator has enough CPUs for enclave
sudo bash -lc "if [ -f /etc/nitro_enclaves/allocator.yaml ]; then \
  sudo sed -i 's/^cpu_count:.*/cpu_count: 2/' /etc/nitro_enclaves/allocator.yaml; \
  sudo systemctl enable --now nitro-enclaves-allocator.service >/dev/null; \
fi"

# Start tinyproxy and expose it over vsock for enclave HTTP(S)_PROXY
echo "[remote] Starting tinyproxy and vsock proxy bridge..."
sudo pkill -f 'tinyproxy.*tinyproxy.get_keys.conf' 2>/dev/null || true
nohup sudo tinyproxy -d -c "${SCRIPT_DIR}/tinyproxy.get_keys.conf" > /tmp/tinyproxy.log 2>&1 &
TINYPROXY_PID=$!
sleep 2
if ps -p ${TINYPROXY_PID} > /dev/null 2>&1; then
  echo "[remote] tinyproxy started (PID=${TINYPROXY_PID})"
else
  echo "[remote] ERROR: tinyproxy failed to start, logs:"
  cat /tmp/tinyproxy.log || true
fi

sudo pkill -f 'socat.*VSOCK-LISTEN:3128' 2>/dev/null || true
sleep 1
nohup sudo socat VSOCK-LISTEN:3128,fork,reuseaddr TCP:127.0.0.1:3128 > /tmp/socat_proxy.log 2>&1 &
SOCAT_PROXY_PID=$!
sleep 3
if ps -p ${SOCAT_PROXY_PID} > /dev/null 2>&1; then
  echo "[remote] socat vsock-to-tinyproxy bridge started (PID=${SOCAT_PROXY_PID})"
else
  echo "[remote] ERROR: socat vsock-to-tinyproxy bridge failed to start, logs:"
  cat /tmp/socat_proxy.log || true
fi

# Clean up old enclave and listener
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli terminate-enclave --all 2>/dev/null || true"
sudo rm -f "${REMOTE_JSON}"

# Start vsock listener (host side) to capture keys
sudo ncat --vsock -l 9999 > "${REMOTE_JSON}" 2>/dev/null &
NCAT_PID=$!
sleep 2

# Run enclave
sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli run-enclave --cpu-count 2 --memory 256 --enclave-cid 16 --eif-path ${REMOTE_EIF} --debug-mode"
ENCLAVE_ID=$(sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && nitro-cli describe-enclaves" | jq -r '.[0].EnclaveID // empty')
if [ -n "${ENCLAVE_ID}" ]; then
  echo "[remote] Capturing enclave console output..."
  sudo bash -lc "source /etc/profile.d/nitro-cli-env.sh && timeout 18 nitro-cli console --enclave-id ${ENCLAVE_ID}" 2>&1 || true
fi

# Wait for enclave to finish and data to be written
sleep 5

# Stop listener and fix permissions
sudo kill ${NCAT_PID} 2>/dev/null || true
sudo chown ubuntu:ubuntu "${REMOTE_JSON}" || true
ls -l "${REMOTE_JSON}"
