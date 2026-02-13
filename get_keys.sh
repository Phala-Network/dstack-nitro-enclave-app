#!/usr/bin/env bash
# Usage:
#   HOST=3.227.1.201 KMS_URL=https://kms:12001 ./get_keys.sh
#   HOST=3.227.1.201 ./get_keys.sh --show-mrs   # build EIF and print measurements only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
SHOW_MRS=0
POSITIONAL_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --show-mrs) SHOW_MRS=1 ;;
    *) POSITIONAL_ARGS+=("${arg}") ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

HOST=${HOST:-${1:-}}
KMS_URL=${KMS_URL:-https://kms.tdxlab.dstack.org:12001}
APP_ID=${APP_ID:-}
KEY_PATH=${KEY_PATH:-"$PWD/nitro-enclave-key.pem"}
SSH_USER=${SSH_USER:-ec2-user}
REMOTE_JSON=${REMOTE_JSON:-/tmp/app_keys.json}
REMOTE_EIF=${REMOTE_EIF:-/home/${SSH_USER}/dstack-get-keys.eif}
REMOTE_BIN=${REMOTE_BIN:-/home/${SSH_USER}/dstack-util}
LOCAL_JSON=${LOCAL_JSON:-"$(pwd)/app_keys.json"}
LOCAL_ENCLAVE_LOG=${LOCAL_ENCLAVE_LOG:-"$(pwd)/enclave_console.log"}
LOCAL_NCAT_LOG=${LOCAL_NCAT_LOG:-"$(pwd)/ncat_keys.log"}
REMOTE_HOME="/home/${SSH_USER}"

if [[ -z "${HOST}" && ! -f deployment.json ]]; then
  echo "Usage: HOST=<public_ip> KMS_URL=<https://kms> ./get_keys.sh" >&2
  exit 1
fi
HOST=${HOST:-$(jq -r .public_ip < deployment.json)}

if [[ "${SHOW_MRS}" -eq 0 && -z "${KMS_URL}" ]]; then
  echo "KMS_URL is required" >&2
  exit 1
fi

if [[ -z "${APP_ID}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    APP_ID="$(openssl rand -hex 20)"
  else
    APP_ID="$(hexdump -n 20 -e '20/1 "%02x"' /dev/urandom)"
  fi
  echo "[local] Generated APP_ID=${APP_ID}"
fi

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "SSH key not found: ${KEY_PATH}" >&2
  exit 1
fi
KEY_PATH="$(cd "$(dirname "${KEY_PATH}")" && pwd)/$(basename "${KEY_PATH}")"

SSH_OPTS=("-o" "StrictHostKeyChecking=no" "-i" "${KEY_PATH}")

# Build local dstack-util (musl)
echo "[local] Building dstack-util (musl)..."
cd "${ROOT_DIR}/dstack"
cargo build --release -p dstack-util --target x86_64-unknown-linux-musl >/dev/null
LOCAL_DSTACK="$(pwd)/target/x86_64-unknown-linux-musl/release/dstack-util"
echo "[local] Built ${LOCAL_DSTACK}"

# Upload binary and build scripts
echo "[local] Uploading dstack-util and get-keys scripts to host..."
scp "${SSH_OPTS[@]}" "${LOCAL_DSTACK}" "${SSH_USER}@${HOST}:${REMOTE_BIN}" >/dev/null
GET_KEYS_DIR="${ROOT_DIR}/get-keys"
if [[ ! -d "${GET_KEYS_DIR}" ]]; then
  echo "Missing directory: ${GET_KEYS_DIR}" >&2
  exit 1
fi
TMP_GET_KEYS_DIR="$(mktemp -d)"
cp -a "${GET_KEYS_DIR}/." "${TMP_GET_KEYS_DIR}/"
RUN_GET_KEYS_TEMPLATE="${GET_KEYS_DIR}/enclave_run_get_keys.sh"
RUN_GET_KEYS_RENDERED="${TMP_GET_KEYS_DIR}/enclave_run_get_keys.sh"
KMS_URL_ESCAPED=$(printf '%s' "${KMS_URL}" | sed -e 's/[\\/&]/\\&/g')
APP_ID_ESCAPED=$(printf '%s' "${APP_ID}" | sed -e 's/[\\/&]/\\&/g')
sed -e "s/__KMS_URL__/${KMS_URL_ESCAPED}/g" -e "s/__APP_ID__/${APP_ID_ESCAPED}/g" \
  "${RUN_GET_KEYS_TEMPLATE}" > "${RUN_GET_KEYS_RENDERED}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "rm -rf ${REMOTE_HOME}/get-keys"
scp -r "${SSH_OPTS[@]}" "${TMP_GET_KEYS_DIR}" "${SSH_USER}@${HOST}:${REMOTE_HOME}/get-keys" >/dev/null
rm -rf "${TMP_GET_KEYS_DIR}"

# --show-mrs: build EIF, print PCR values and OS_IMAGE_HASH, then exit
if [[ "${SHOW_MRS}" -eq 1 ]]; then
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" bash -s <<'SHOW_MRS_EOF'
set -euo pipefail
[ -f /etc/profile.d/nitro-cli-env.sh ] && source /etc/profile.d/nitro-cli-env.sh || true
SCRIPT_DIR="${HOME}/get-keys"
chmod +x "${SCRIPT_DIR}/enclave_run_get_keys.sh"
cp -f "${HOME}/dstack-util" "${SCRIPT_DIR}/dstack-util"
sudo docker build -t dstack-get-keys -f "${SCRIPT_DIR}/Dockerfile.get_keys" "${SCRIPT_DIR}" >/dev/null
sudo nitro-cli build-enclave --docker-uri dstack-get-keys --output-file /tmp/show-mrs.eif > /tmp/build-enclave.json
PCR0=$(jq -r '.Measurements.PCR0' /tmp/build-enclave.json)
PCR1=$(jq -r '.Measurements.PCR1' /tmp/build-enclave.json)
PCR2=$(jq -r '.Measurements.PCR2' /tmp/build-enclave.json)
OS_IMAGE_HASH=$(python3 -c "
import hashlib
h = hashlib.sha256(bytes.fromhex('${PCR0}') + bytes.fromhex('${PCR1}') + bytes.fromhex('${PCR2}')).hexdigest()
print('0x' + h)
")
echo "PCR0: ${PCR0}"
echo "PCR1: ${PCR1}"
echo "PCR2: ${PCR2}"
echo "OS_IMAGE_HASH: ${OS_IMAGE_HASH}"
SHOW_MRS_EOF
  exit 0
fi

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" REMOTE_EIF="${REMOTE_EIF}" REMOTE_JSON="${REMOTE_JSON}" \
  DEBUG_ENCLAVE="${DEBUG_ENCLAVE:-0}" bash "${REMOTE_HOME}/get-keys/remote_run.sh"

# Copy the json file back
scp "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}:${REMOTE_JSON}" "${LOCAL_JSON}" >/dev/null
scp "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}:/tmp/enclave_console.log" "${LOCAL_ENCLAVE_LOG}" >/dev/null || true
scp "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}:/tmp/ncat_keys.log" "${LOCAL_NCAT_LOG}" >/dev/null || true

echo "Saved app keys to ${LOCAL_JSON} (size: $(stat -c%s "${LOCAL_JSON}") bytes)"
if [[ -f "${LOCAL_ENCLAVE_LOG}" ]]; then
  echo "Saved enclave console log to ${LOCAL_ENCLAVE_LOG}"
fi
if [[ -f "${LOCAL_NCAT_LOG}" ]]; then
  echo "Saved ncat log to ${LOCAL_NCAT_LOG}"
fi
