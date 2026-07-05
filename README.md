# opale-infrastructure

Infrastructure-as-code repository for Opale services on Infomaniak Cloud using OpenStack and Terraform.

This repository is the canonical provisioning layer for long-lived Opale VMs. It is responsible for:

- provisioning instances and security groups;
- applying a baseline hardening profile;
- standardizing naming, ports, and filesystem layout;
- keeping Terraform state in a remote backend;
- exposing only the minimum admin and app surfaces required by each service.

It is also the canonical home for deployment-owned infrastructure configuration that does not belong in product repositories, including the public Oracle edge configuration.

It is not a secret store and must never contain long-lived application secrets.

## Current Scope

The current implementation provisions the first critical VMs:

- `opale-vault-prod`
- `opale-pay-prod`
- IFK-hosted `bitcoind` runtime for Opale Pay

These VMs are intended to become hardened runtimes for the first sensitive Opale control planes.

Opale Pay's deployment topology is split deliberately:

- frontend: product container on the Oracle VPS, exposed by the shared
  infrastructure-owned edge under `/pay`;
- backend: OpenStack VM `opale-pay-prod`, Ubuntu 26.04 LTS on
  `a1-ram2-disk20-perf1` (1 vCPU / 2 Go RAM / 20 Go disk);
- Bitcoin backend: `bitcoind` on the IFK VPS, reachable only over WireGuard at
  `10.77.0.1:18332`.

## Repository Layout

```text
edge-oracle/
  Dockerfile
  Caddyfile
  docker-compose.yml
  sites/
ifk-bitcoind/
  docker-compose.yml
  README.md
  wireguard.env.example
infra-vault/
  main.tf
  variables.tf
  outputs.tf
  cloud-init.yaml.tftpl
infra-pay/
  main.tf
  variables.tf
  outputs.tf
  cloud-init.yaml.tftpl
infra-data/
  main.tf
  variables.tf
  outputs.tf
  cloud-init.yaml.tftpl
scripts/
  apply-ifk-bitcoind.sh
  harden-ubuntu-vps.sh
  harden-alpine-vps.sh   # legacy, kept until the Alpine Vault VM is retired
  opale-vault-sync.sh
.github/workflows/
  infra-deploy.yml           # vault: plan on push, apply via dispatch + confirm
  infra-deploy-pay.yml
  infra-deploy-data.yml
  ifk-bitcoind-config.yml
  edge-oracle-deploy.yml
  vault-server-list.yml
  vault-server-show.yml
  vault-server-delete.yml    # manual, double-confirmed
  pay-server-list.yml
  pay-server-show.yml
  pay-server-delete.yml
  vps-control.yml
  vps-control-pay.yml
  backend-bootstrap-window.yml
```

## Vault VM Migration (Alpine → Ubuntu)

`infra-vault` provisions Ubuntu LTS with vTPM and cloud-init hardening, per the
DevOps doctrine. The legacy Alpine VM is replaced through an explicit,
human-driven sequence — never implicitly on push:

1. Verify Vault backups (the master key is sealed in the old VM's vTPM and
   cannot be migrated; only the backup/restore path survives the VM).
2. `vault-server-list` / `vault-server-show`: identify the Alpine server ID.
3. `vault-server-delete` with the ID and the `DELETE-VAULT-VM` confirmation —
   or skip and let Terraform plan a replacement.
4. Dispatch `infra-deploy.yml` with `confirm_replace=opale-vault-prod`: creates
   the Ubuntu VM (vTPM, cloud-init hardening) and publishes the new IP to
   `opale-core` secrets.
5. Open a bootstrap SSH window via `backend-bootstrap-window.yml` if needed,
   deploy the backend from `opale-core`, restore from backup, re-init the TPM
   seal.

Pushes touching `infra-vault/**` only run `terraform plan`.

## Conventions

### Naming

- VM: `opale-<service>-<env>`
- security group: `opale-<service>-secgroup`
- keypair: `opale-<service>-key`
- app dir: `/opt/<service>`
- state key: `<env>/<service>/terraform.tfstate`

### Base Runtime

- Ubuntu 26.04 LTS Resolute Raccoon for all Infomaniak/OpenStack VMs.
- SSH on a non-default admin port.
- `PasswordAuthentication no`.
- Firewall default-drop.
- Fail2ban, auditd, sysctl hardening.
- Docker configured with reduced privileges and log rotation when needed.

### Oracle Edge

- The Oracle edge VPS is not provisioned by Terraform.
- Its deployment configuration still belongs in `opale-infrastructure`.
- Reverse proxy configuration, host hardening, validation, and healthchecks for Oracle edge should live here rather than in `OpaleVault` or `OpalePay`.
- Opale Pay frontend routing is infrastructure-owned here (`/pay` to
  `opale-pay-frontend:80` on the shared `opale-edge` Docker network).
- Oracle edge changes should be repeatable and idempotent, with config validation before reload and a post-deploy healthcheck.
- A full WAF rollout with Coraza requires the shared Oracle proxy runtime itself to be versioned and deployed as infrastructure, because stock Caddy cannot load `coraza_waf` without a custom build.
- Until that shared proxy lifecycle is owned here, product repos may only ship stock-Caddy-safe hardening such as security headers and strict method/content-type guards on sensitive API routes.

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

Additional dedicated secrets for Opale Pay:

- `OPALE_PAY_SSH_PUBLIC_KEY`
- `OPALE_PAY_ADMIN_CIDR`
- `OPALE_PAY_ALLOWED_CIDR`

## Usage

### Plan locally

```bash
cd infra-vault
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

`infra-deploy.yml` and `infra-deploy-pay.yml` run `init`, `plan`, and `apply`
on infrastructure changes because the hardening baseline is embedded into the VM
`user_data`.

`edge-oracle-deploy.yml` builds and deploys the shared Oracle public proxy as
an infrastructure-owned artifact.

`pay-wireguard-config.yml` configures the WireGuard peer on the Opale Pay VM so
it can reach the IFK-hosted `bitcoind` RPC through a private tunnel.

`ifk-bitcoind-config.yml` configures the IFK side of the tunnel and the
IFK-hosted `bitcoind` runtime from versioned infrastructure artifacts.

The intended delivery boundary is:

1. Terraform provisions the VM, networking, and first-boot hardening baseline.
2. `cloud-init` performs machine bootstrap only.
3. The application VM remains a passive deployment target.
4. Application rollout is triggered explicitly by CI/CD from the product side.

For `opale-pay`, the infrastructure workflow publishes the VM connection target
to the `OpalePay` repository so the product pipeline can push the selected
release explicitly.

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
- [ ] The VM bootstrap completes without embedding application deployment logic.
- [ ] The product pipeline can deploy explicitly to the provisioned target.

## Next Improvements

- Add a dedicated cloud-init template per service.
- Split service modules by role if more VMs are added.
- Add reverse proxy/TLS conventions for public services.
- Add post-provision verification workflow.
