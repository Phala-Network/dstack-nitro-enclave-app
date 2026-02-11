#!/bin/sh
set -e

# Configure loopback interface (required in enclave)
ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null || true

# Start socat to forward TCP:3128 -> vsock CID 3 port 3128 (HTTP proxy bridge)
socat TCP-LISTEN:3128,fork,reuseaddr VSOCK-CONNECT:3:3128 &
sleep 1

# Use passed KMS_URL for TLS validation; proxy handles egress
KMS_URL="__KMS_URL__"
APP_ID="__APP_ID__"
ARGS="--kms-url ${KMS_URL}"
if [ -n "${APP_ID}" ]; then
  ARGS="${ARGS} --app-id ${APP_ID}"
fi

HTTPS_PROXY="http://127.0.0.1:3128"
HTTP_PROXY="${HTTPS_PROXY}"
ALL_PROXY="${HTTPS_PROXY}"
NO_PROXY="127.0.0.1,localhost"
echo "[enclave] run dstack-util get-keys" >&2
set +e
KEYS=$(HTTPS_PROXY="${HTTPS_PROXY}" HTTP_PROXY="${HTTP_PROXY}" ALL_PROXY="${ALL_PROXY}" NO_PROXY="${NO_PROXY}" /app/dstack-util get-keys ${ARGS} 2>/tmp/get_keys.stderr)
RET=$?
set -e
echo "[enclave] dstack-util exit=${RET}" >&2
if [ -s /tmp/get_keys.stderr ]; then
  echo "[enclave] dstack-util stderr:" >&2
  cat /tmp/get_keys.stderr >&2
fi
if [ "${RET}" -ne 0 ]; then
  sleep 5
  exit "${RET}"
fi

echo "[enclave] keys-bytes=$(printf '%s' "${KEYS}" | wc -c)" >&2
printf '%s' "${KEYS}" > /tmp/app_keys.json
echo "[enclave] sending keys to host vsock:9999" >&2
printf '%s' "${KEYS}" | socat -u - VSOCK-CONNECT:3:9999
sleep 2
