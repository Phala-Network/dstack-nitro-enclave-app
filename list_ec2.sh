#!/usr/bin/env bash
set -euo pipefail

REGIONS=us-east-1

for r in $REGIONS; do
  echo "=== Region: $r ==="
  aws ec2 describe-instances \
    --region "$r" \
    --query 'Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}' \
    --output table
  echo
done
