# Nitro-KMS Walkthrough

## Agenda

1. How dstack-kms on GCP work
2. Nitro Enclave Key Retrieval Flow
3. Deploy KMS to GCP

---

## 1. How dstack-kms on GCP work

### What Gets Stored

| File | Purpose |
|------|---------|
| `root-ca.key` | Root CA private key (ECDSA P-256) |
| `root-k256.key` | Ethereum signing key (secp256k1) |

### Storage Security

KMS runs inside a GCP TDX VM. The disk encryption key is generated inside the VM on first boot and sealed to vTPM, bound to specific PCR values.

**PCR Binding Policy** (`sha256:0,2,14`):

| PCR | Content |
|-----|---------|
| 0 | Firmware version + memory encryption info |
| 2 | UKI image (kernel + initrd + initramfs) |
| 14 | App compose hash |

**First Boot Flow**:
1. VM generates random disk encryption key inside TDX
2. Key sealed to vTPM with PCR policy
3. LUKS volume formatted with the key
4. Root keys stored on encrypted disk

**Subsequent Boot**:
1. vTPM checks PCR 0, 2, 14 values
2. If PCRs match → unseal disk key → mount encrypted disk
3. If any PCR changed (code/firmware modified) → unseal fails → data inaccessible

```
┌───────────────────────────────────────────────┐
│              GCP TDX Instance                 │
│  ┌─────────────────────────────────────────┐  │
│  │              dstack-kms                 │  │
│  │                                         │  │
│  │   /etc/kms/certs/    ←──┐               │  │
│  │   - root-ca.key         │               │  │
│  │   - root-k256.key       │               │  │
│  │                         │               │  │
│  │   LUKS Encrypted     ───┘               │  │
│  │   Disk Volume                           │  │
│  │        ↑                                │  │
│  │   disk_key (sealed in vTPM)             │  │
│  │        ↑                                │  │
│  │   PCR Policy: sha256:0,2,14             │  │
│  └─────────────────────────────────────────┘  │
│                    ↑                          │
│         TDX protected VM                      │
└───────────────────────────────────────────────┘
```

**Security Guarantee**: Any modification to firmware, OS image, or app configuration will change PCR values, preventing disk key retrieval.

### Key Derivation

App keys are **derived**, not stored:

```rust
// Disk encryption key
disk_key = HKDF(root_ca_key, [app_id, instance_id, "app-disk-crypt-key"])

// Environment encryption key
env_key = HKDF(root_ca_key, [app_id, "env-encrypt-key"])

// Ethereum signing key
k256_key = HKDF(root_k256_key, app_id)
```

---

## 2. Nitro Enclave Key Retrieval

### Architecture

```
┌─────────────────────────────────────────────────┐
│                  AWS EC2 Host                   │
│  ┌───────────────────────┐                      │
│  │    Nitro Enclave      │      ┌────────────┐  │
│  │                       │      │  tinyproxy │  │
│  │ ┌───────────────────┐ │ vsock│  (HTTP     │  │
│  │ │dstack-util get-key│─┼──────│   proxy)   │  │
│  │ └───────────────────┘ │ :3128└─────┬──────┘  │
│  │          ↓            │            │         │
│  │ ┌───────────────────┐ │            │         │
│  │ │     /dev/nsm      │ │            │         │
│  │ └───────────────────┘ │            │         │
│  └───────────────────────┘            │         │
└───────────────────────────────────────┼─────────┘
                                        │ HTTP over RA-TLS
                                        ▼
                          ┌──────────────────────┐
                          │     dstack KMS       │
                          │     (on GCP TDX)     │
                          │  ┌────────────────┐  │
                          │  │  KMS Service   │  │
                          │  └────────────────┘  │
                          └──────────────────────┘
```

Nitro Enclave has no network access. Traffic goes through vsock to host proxy, then HTTPS to KMS.

### Step-by-Step Flow

```
┌─────────────────┐                              ┌─────────────────┐
│  Nitro Enclave  │                              │   dstack KMS    │
└────────┬────────┘                              └────────┬────────┘
         │                                                │
         │  1. Generate key pair (ECDSA P-256)            │
         │     report_data = sha256(pubkey)               │
         │     Call /dev/nsm → get NSM quote              │
         │     Embed quote in X.509 cert extension        │
         │                                                │
         │  2. GetAppKey() with RA-TLS client cert ──────>│
         │     (cert contains NSM attestation)            │
         │                                                │
         │                         3. KMS verification:   │
         │                            - Extract quote     │
         │                            - Verify COSE_Sign1 │
         │                            - Check cert chain  │
         │                              to AWS root       │
         │                            - Validate PCRs     │
         │                            - Check auth policy │
         │                                                │
         │                         4. Derive app keys:    │
         │                            - disk_crypt_key    │
         │                            - env_crypt_key     │
         │                            - k256_key          │
         │                                                │
         │<──────────────────────────── AppKeyResponse ───│
         │                                                │
         ▼                                                ▼
```

**Key Points**:
- Step 1-2 happen in Nitro Enclave
- Step 3-4 happen in KMS
- NSM quote embedded in TLS client certificate proves enclave identity
- KMS verifies quote against AWS Nitro root CA before releasing keys

---

## Nitro Attestation Deep Dive

### NSM Quote Structure

```
COSE_Sign1 {
    protected: { alg: ES384 (-35) },
    unprotected: {},
    payload: {
        module_id: "i-1234567890abcdef0-enc9876543210abcde",
        pcrs: {
            0: [48 bytes],  // Enclave image hash
            1: [48 bytes],  // App image hash
            2: [48 bytes],  // Firmware hash
        },
        user_data: [64 bytes],  // report_data
        timestamp: 1234567890,
        certificate: [DER],     // Leaf cert
        cabundle: [[DER], ...], // Intermediate certs
    },
    signature: [96 bytes],
}
```

### Verification Chain

```
AWS Nitro Enclaves Root G1 (hardcoded)
           │
           ▼
    Intermediate CAs (from cabundle)
           │
           ▼
    Leaf Certificate (from quote)
           │
           ▼
    ECDSA P-384 Signature
           │
           ▼
    Quote payload (pcrs, user_data, etc.)
```

---

## Demo: Running in Nitro Enclave

### On Host (EC2 with Nitro Enclave support)

```bash
# Build enclave image
docker build -t get-keys -f Dockerfile.get_keys .
nitro-cli build-enclave --docker-uri get-keys:latest --output-file get-keys.eif

# Start enclave
nitro-cli run-enclave --cpu-count 2 --memory 256 --eif-path get-keys.eif
```

### Inside Enclave

```bash
# Set proxy (vsock bridge to host network)
export HTTPS_PROXY="http://127.0.0.1:3128"

# Fetch keys from KMS
dstack-util get-keys \
  --kms-url https://kms.example.com:8000 \
  --root-ca path/to/kms/root-ca.pem \
  --app-id 0x1234...

# Output:
{
  "ca_cert": "-----BEGIN CERTIFICATE-----...",
  "disk_crypt_key": "base64...",
  "env_crypt_key": "base64...",
  "k256_key": "base64...",
  "k256_signature": "base64...",
  "gateway_app_id": "0x..."
}
```

---

## 3. Deploy KMS via dstack-cloud

### Steps (host)

```bash
# Initialize demo project
dstack-cloud new --tpm nitro-kms-demo
cd nitro-kms-demo/

# Inspect/adjust docker-compose.yaml and app.json
cat docker-compose.yaml

# Deploy
dstack-cloud deploy
```

Example `docker-compose.yaml`

```yaml
services:
  kms:
    image: cr.kvin.wang/dstack-kms@sha256:39db625ab98b6a3faae46c8466e742350027ad493842f0ab9802167406ed23de
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
    ports:
      - "8000:8000"
    restart: unless-stopped
```
