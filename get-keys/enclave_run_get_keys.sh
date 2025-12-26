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
KEYS=$(HTTPS_PROXY="${HTTPS_PROXY}" HTTP_PROXY="${HTTP_PROXY}" ALL_PROXY="${ALL_PROXY}" NO_PROXY="${NO_PROXY}" /app/dstack-util get-keys ${ARGS})
echo "${KEYS}" | socat -t 20 STDIN VSOCK-CONNECT:3:9999
