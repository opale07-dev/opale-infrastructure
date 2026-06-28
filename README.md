# opale-infrastructure

Infrastructure-as-code repository for Opale services on Infomaniak Cloud using OpenStack and Terraform.

This repository is the canonical provisioning layer for long-lived Opale VMs. It is responsible for:

- provisioning instances and security groups;
- applying a baseline hardening profile;
- standardizing naming, ports, and filesystem layout;
- keeping Terraform state in a remote backend;
- exposing only the minimum admin and app surfaces required by each service.

It is not a secret store and must never contain long-lived application secrets.

## Current Scope

The current implementation provisions the first critical VM:

- `opale-vault-prod`

This VM is intended to become the first hardened runtime for the Opale Vault control plane.

## Repository Layout

```text
infra/
  main.tf
  variables.tf
  outputs.tf
scripts/
  harden-alpine-vps.sh
  opale-vault-sync.sh
.github/workflows/
  infra-deploy.yml
  vps-control.yml
```

## Conventions

### Naming

- VM: `opale-<service>-<env>`
- security group: `opale-<service>-secgroup`
- keypair: `opale-<service>-key`
- app dir: `/opt/<service>`
- state key: `<env>/<service>/terraform.tfstate`

### Base Runtime

- Alpine Linux by default for lean service nodes.
- SSH on a non-default admin port.
- `PasswordAuthentication no`.
- Firewall default-drop.
- Fail2ban, auditd, sysctl hardening.
- Docker configured with reduced privileges and log rotation when needed.

### Secrets

- No application secret in Terraform code.
- No durable secret in `user_data`.
- OpenStack and S3 backend credentials come from CI secrets or local env.
- Application secrets are injected after provisioning through the host-local deploy env, not baked into Terraform or `user_data`.

## Prerequisites

### Local

- Terraform `>= 1.5.0`
- OpenStack credentials exported in the shell or sourced from OpenRC
- S3-compatible backend credentials for Infomaniak object storage

### GitHub Actions

Required secrets:

- `OS_AUTH_URL`
- `OS_PROJECT_ID`
- `OS_PROJECT_NAME`
- `OS_USER_DOMAIN_NAME`
- `OS_PROJECT_DOMAIN_NAME`
- `OS_USERNAME`
- `OS_PASSWORD`
- `OS_REGION_NAME`
- `INFOMANIAK_S3_ACCESS_KEY`
- `INFOMANIAK_S3_SECRET_KEY`
- `SSH_PUBLIC_KEY`
- `ADMIN_CIDR`
- `VAULT_ALLOWED_CIDR`

## Usage

### Plan locally

```bash
cd infra
terraform init \
  -backend-config="endpoint=https://s3.pub2.infomaniak.cloud" \
  -backend-config="skip_requesting_account_id=true" \
  -backend-config="skip_credentials_validation=true" \
  -backend-config="skip_region_validation=true" \
  -backend-config="skip_metadata_api_check=true" \
  -backend-config="skip_s3_checksum=true" \
  -backend-config="force_path_style=true"

terraform plan \
  -var="ssh_public_key=${SSH_PUBLIC_KEY}" \
  -var="admin_cidr=<your_public_ip>/32" \
  -var="vault_allowed_cidr=<trusted_ip>/32"
```

### Apply locally

```bash
terraform apply \
  -var="ssh_public_key=${SSH_PUBLIC_KEY}" \
  -var="admin_cidr=<your_public_ip>/32" \
  -var="vault_allowed_cidr=<trusted_ip>/32"
```

### CI/CD

`infra-deploy.yml` runs `init`, `plan`, and `apply` on pushes to `main` that touch `infra/**`
or `scripts/**`, because the hardening script is embedded into the VM `user_data`.

The current chain is:

1. Terraform provisions the VM and first-boot hardening baseline.
2. Terraform installs a local `opale-vault-sync` script on the VM.
3. The VM pulls the deployment bundle (`docker-compose.prod.yml`, `Caddyfile`) and the latest image from `opale-core`/GHCR.
4. The VM applies the compose state at boot and every 15 minutes without requiring inbound CI SSH access.

The one-time manual action is to fill `/opt/opale-vault/deploy.env` on the VM with:

- `GITHUB_DEPLOY_USER`
- `GITHUB_DEPLOY_PAT` with `repo` + `read:packages`
- `VAULT_ADMIN_PUBKEYS`
- optionally `VAULT_TPM_NV_INDEX`

After that, backend deployment is pull-based and autonomous.

## Security Notes

- Do not leave admin SSH open to `0.0.0.0/0` unless this is a short-lived exception.
- Do not rely on Terraform comments as security controls; the actual security group values must be restrictive.
- Do not use this repository to store private keys, seed phrases, API secrets, or wallet material.
- Do not consider provisioning complete until the hardening script has actually run on the instance.

## Acceptance Checklist

- [ ] Terraform state is remote.
- [ ] Security groups are dedicated and least-privilege.
- [ ] SSH is restricted to trusted CIDRs.
- [ ] The hardening baseline runs successfully on first boot.
- [ ] The app directory exists under `/opt/<service>`.
- [ ] No application secret is stored in Terraform or `user_data`.
- [ ] The service port model is documented: internal port, public port, admin port.
- [ ] CI injects `ADMIN_CIDR` and `VAULT_ALLOWED_CIDR`.
- [ ] `/opt/opale-vault/deploy.env` is populated once with GitHub/registry credentials and runtime admin values.
- [ ] `/usr/local/bin/opale-vault-sync` succeeds manually on the VM.
- [ ] The periodic pull-based sync can update the backend without inbound CI SSH access.

## Next Improvements

- Add a dedicated cloud-init template per service.
- Split service modules by role if more VMs are added.
- Add reverse proxy/TLS conventions for public services.
- Add post-provision verification workflow.
