# dstack nitro enclave app example

This repo is a tiny example for working with Nitro Enclave demo scripts.

## Quick use

1. Install the AWS CLI and log in (`aws login` or SSO).
2. Run `./deploy_host.sh` to deploy the host instance.
3. Run `./get_keys.sh` to connect to the hose instance and deploy and demo enclave which will fetch keys from dstack KMS.
