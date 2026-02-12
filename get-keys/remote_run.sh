#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_EIF="${REMOTE_EIF:?REMOTE_EIF is required}"
REMOTE_JSON="${REMOTE_JSON:?REMOTE_JSON is required}"
CURRENT_USER="$(whoami)"

# Source nitro-cli env if available (Ubuntu source-build path)
[ -f /etc/profile.d/nitro-cli-env.sh ] && source /etc/profile.d/nitro-cli-env.sh || true

# Ensure ncat, jq, socat, and a forward proxy are available
if command -v apt-get >/dev/null 2>&1; then
  PKGS=""
  command -v ncat >/dev/null 2>&1 || PKGS="$PKGS ncat"
  command -v jq >/dev/null 2>&1 || PKGS="$PKGS jq"
  command -v socat >/dev/null 2>&1 || PKGS="$PKGS socat"
  command -v tinyproxy >/dev/null 2>&1 || PKGS="$PKGS tinyproxy"
  if [ -n "$PKGS" ]; then
    sudo apt-get update -y >/dev/null
    sudo apt-get install -y $PKGS >/dev/null
  fi
  PROXY_CMD="tinyproxy"
elif command -v dnf >/dev/null 2>&1; then
  PKGS=""
  command -v ncat >/dev/null 2>&1 || PKGS="$PKGS nmap-ncat"
  command -v jq >/dev/null 2>&1 || PKGS="$PKGS jq"
  command -v socat >/dev/null 2>&1 || PKGS="$PKGS socat"
  command -v squid >/dev/null 2>&1 || PKGS="$PKGS squid"
  if [ -n "$PKGS" ]; then
    sudo dnf install -y $PKGS >/dev/null
  fi
  PROXY_CMD="squid"
else
  echo "ERROR: unsupported package manager" >&2; exit 1
fi

# Build EIF from uploaded binary
chmod +x "${SCRIPT_DIR}/enclave_run_get_keys.sh"
cp -f "${HOME}/dstack-util" "${SCRIPT_DIR}/dstack-util"

sudo docker build -t dstack-get-keys -f "${SCRIPT_DIR}/Dockerfile.get_keys" "${SCRIPT_DIR}" >/dev/null
sudo nitro-cli build-enclave --docker-uri dstack-get-keys --output-file "${REMOTE_EIF}" >/dev/null

# Ensure allocator has enough CPUs for enclave
if [ -f /etc/nitro_enclaves/allocator.yaml ]; then
  sudo sed -i 's/^cpu_count:.*/cpu_count: 2/' /etc/nitro_enclaves/allocator.yaml
  sudo systemctl enable --now nitro-enclaves-allocator.service >/dev/null
fi

# Start forward proxy and expose it over vsock for enclave HTTP(S)_PROXY
echo "[remote] Starting forward proxy (${PROXY_CMD}) and vsock proxy bridge..."
sudo systemctl stop tinyproxy 2>/dev/null || true
sudo systemctl stop squid 2>/dev/null || true
sudo pkill tinyproxy 2>/dev/null || true
sudo pkill squid 2>/dev/null || true
sleep 1

if [ "${PROXY_CMD}" = "tinyproxy" ]; then
  nohup sudo tinyproxy -d -c "${SCRIPT_DIR}/tinyproxy.get_keys.conf" > /tmp/proxy.log 2>&1 &
  PROXY_PID=$!
else
  # Minimal squid config for HTTP CONNECT proxy on port 3128
  sudo tee /etc/squid/squid.get_keys.conf >/dev/null <<'SQUIDEOF'
http_port 127.0.0.1:3128
acl SSL_ports port 443
acl SSL_ports port 12001
acl CONNECT method CONNECT
http_access allow CONNECT SSL_ports
http_access deny all
access_log none
cache deny all
SQUIDEOF
  nohup sudo squid -f /etc/squid/squid.get_keys.conf -N > /tmp/proxy.log 2>&1 &
  PROXY_PID=$!
fi
sleep 2
if ps -p ${PROXY_PID} > /dev/null 2>&1; then
  echo "[remote] ${PROXY_CMD} started (PID=${PROXY_PID})"
else
  echo "[remote] ERROR: ${PROXY_CMD} failed to start, logs:"
  cat /tmp/proxy.log || true
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
sudo nitro-cli terminate-enclave --all 2>/dev/null || true
sudo rm -f "${REMOTE_JSON}"

# Start vsock listener (host side) to capture keys
sudo rm -f /tmp/ncat_keys.log
sudo timeout 40 ncat --vsock -l 9999 > "${REMOTE_JSON}" 2>/tmp/ncat_keys.log &
NCAT_PID=$!
sleep 2

# Run enclave
sudo nitro-cli run-enclave --cpu-count 2 --memory 256 --enclave-cid 16 --eif-path "${REMOTE_EIF}" --debug-mode
ENCLAVE_ID=$(sudo nitro-cli describe-enclaves | jq -r '.[0].EnclaveID // empty')
if [ -n "${ENCLAVE_ID}" ]; then
  echo "[remote] Capturing enclave console output..."
  sudo rm -f /tmp/enclave_console.log
  sudo timeout 25 nitro-cli console --enclave-id "${ENCLAVE_ID}" 2>&1 \
    | sudo tee /tmp/enclave_console.log >/dev/null || true
fi

# Wait for enclave to finish and data to be written
sleep 5

# Stop listener and fix permissions
sudo kill ${NCAT_PID} 2>/dev/null || true
sudo chown "${CURRENT_USER}:${CURRENT_USER}" "${REMOTE_JSON}" || true
sudo chown "${CURRENT_USER}:${CURRENT_USER}" /tmp/ncat_keys.log /tmp/enclave_console.log /tmp/proxy.log /tmp/socat_proxy.log 2>/dev/null || true
echo "[remote] ncat log tail:"
tail -n 80 /tmp/ncat_keys.log 2>/dev/null || true
echo "[remote] socat proxy log tail:"
tail -n 80 /tmp/socat_proxy.log 2>/dev/null || true
echo "[remote] proxy log tail:"
tail -n 80 /tmp/proxy.log 2>/dev/null || true
echo "[remote] enclave console log tail:"
tail -n 80 /tmp/enclave_console.log 2>/dev/null || true
ls -l "${REMOTE_JSON}"
