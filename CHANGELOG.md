# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This project does not publish versioned releases yet; dated internal releases
are used until the first public version.

## [Unreleased]

### Changed

- **Transport d'image par bundle (save/load), plus aucun credential GHCR sur
  les VM.** Les pulls GHCR authentifiés par PAT échouent en 403 depuis
  l'extérieur d'Actions (reproduit CI + poste local, tous types de PAT,
  digest comme tag) alors que le chemin GITHUB_TOKEN dans Actions fonctionne
  — asymétrie compatible avec le métering des packages privés hors Actions.
  `vault-app-deploy.yml` et `vault-frontend-deploy.yml` tirent désormais
  l'image sur le runner avec le GITHUB_TOKEN (même pattern éprouvé
  qu'`edge-oracle-deploy`), la re-taguent `rollout-<run_id>`, puis
  docker save → scp → docker load sur la cible. Prérequis one-time : accès
  Actions « Read » accordé à opale-infrastructure sur les packages
  `opale-core` et `opale-vault-frontend`. Secrets `OPALE_GHCR_READ_*`
  devenus inutiles.

### Changed

- **Phase de test — rollout accepte les tags GHCR, pas seulement les digests.**
  Le pull par digest immuable (`@sha256:...`) échoue systématiquement en 403
  sur GHCR (`HEAD .../blobs/sha256:...`) — reproduit identiquement en CI et en
  local (Docker Desktop), avec 3 configurations de PAT différentes
  (fine-grained, classic read:packages+repo) et 2 digests distincts. Cause
  racine non identifiée (probable bug de résolution digest/index OCI côté
  GHCR ou containerd). `vault-app-deploy.yml` et `vault-frontend-deploy.yml`
  acceptent temporairement `ghcr.io/<name>:<tag>` en plus du digest. À
  revisiter : revenir au digest épinglé une fois la cause racine trouvée
  (moins critique en solo/phase de test, cf. discussion avec Greg
  2026-07-07).

### Added

- Application rollout split from Terraform per the CD doctrine (three layers):
  new `Vault / App Deploy` (`vault-app-deploy.yml`) and `Vault / Frontend
  Deploy` (`vault-frontend-deploy.yml`) push the **versioned** deployment
  state from `deploy/opale-vault{,-frontend}/` (compose, Caddyfile,
  predeploy.sh — nothing generated on the fly) and converge with a
  digest-pinned image. `vault-infra-deploy.yml` is Terraform-only again (no
  repository_dispatch, no container job). Vault specifics preserved: TPM
  fail-closed, TLS auto-signé, app.env documenté, volume nommé vault-data.

- `scripts/deploy-ghcr-container.sh`: push-based container rollout helper used
  by infrastructure workflows to deploy immutable private GHCR image digests to
  passive Opale VMs without any VM-side Git pull or self-update loop.
- `vault-infra-deploy.yml`, `pay-infra-deploy.yml`, and
  `data-infra-deploy.yml`: optional `image_ref` dispatch path. Product repos
  publish private GHCR images; opale-infrastructure opens temporary runner SSH,
  deploys the selected digest, healthchecks, and closes the SSH rule.
- `maintenance/`: host maintenance timers owned by opale-infrastructure per the
  revised DevOps doctrine (maintenance ≠ deployment). systemd template units for
  backup (local-first + SHA-256 verify + rotation + optional off-site rsync),
  self-check (health, TLS cert expiry, key-age rotation reminder, backup
  freshness), and weekly idempotent hardening re-apply. Idempotent installer
  `opale-maintenance-install.sh`. `unattended-upgrades` enabled for OS patches.
  Wired into `infra-vault` cloud-init (bundled via `archive_file` + python3
  extract) and installable on an existing VM via
  `scripts/opale-maintenance-remote.sh`. No maintenance job ever pulls
  application code/images.
- `pay-backend-ssh-window.yml`: Opale Pay backend deploys can now open
  and close temporary GitHub Actions SSH access to the VM through Terraform on
  the hardened port `2222`.
- `infra-vault/cloud-init.yaml.tftpl`: first-boot Ubuntu hardening for the
  Vault VM (same pattern as pay/data).
- `vault-server-list.yml`, `vault-server-show.yml`, `vault-server-delete.yml`:
  manual OpenStack server operations for the Vault VM; delete requires the
  `DELETE-VAULT-VM` confirmation.

### Fixed

- `edge-oracle-deploy.yml`: pre-start config validation failed with exit 127
  because the Caddy image has no ENTRYPOINT — the `docker run` command must
  start with `caddy` (`caddy validate ...`), not `validate ...`.
- `edge-oracle-deploy.yml`: the deploy now removes any legacy container still
  publishing 80/443 (e.g. `opale-vault-proxy-1`) before starting the shared
  edge proxy — first deploy failed with "Bind for 0.0.0.0:443 failed".
- `vault-backend-ssh-window.yml`: fixed stale `working-directory: ./infra`
  (the stack lives in `./infra-vault`).
- Vault workflows now use a dedicated `VAULT_SSH_PUBLIC_KEY` secret (paired
  with `SSH_PRIVATE_KEY` on opale-core) instead of the shared
  `SSH_PUBLIC_KEY` — the previous pairing was mismatched and broke the
  backend deploy with "Permission denied (publickey)". Pay/Data stacks keep
  the shared key.
- `infra-vault`: `image_id` added to `lifecycle.ignore_changes` so a newer
  `most_recent` Ubuntu image can never trigger an implicit VM replacement
  during routine applies (e.g. SSH window); image migrations must use an
  explicit `terraform apply -replace`.

### Changed

- Product repos no longer receive VM deployment targets from infra workflows.
  They own tests/builds/scans/GHCR publication only; opale-infrastructure owns
  provisioning, VM configuration, and container rollout.
- `infra-vault` standardized on Ubuntu LTS minimal per the DevOps doctrine
  (vTPM metadata preserved, config_drive enabled).
- `vault-infra-deploy.yml`: push now runs Terraform plan/apply for
  non-destructive Vault VM changes; `prevent_destroy` blocks accidental TPM VM
  replacement.
- `infra-pay`: backend VM sizing is aligned with Vault on
  `a1-ram2-disk20-perf1` (1 vCPU / 2 Go RAM / 20 Go disk), and routine applies
  ignore `image_id` drift from the `most_recent` Ubuntu lookup.
- `harden-ubuntu-vps.sh`: Docker Compose package installation is now tolerant
  of Ubuntu repository/package-name drift, so SSH hardening can complete even
  when `docker-compose-plugin` is unavailable in the image's apt sources.
- `ifk-bitcoind-config.yml` and `scripts/apply-ifk-bitcoind.sh`: IFK WireGuard
  and `bitcoind` host configuration are now applied from versioned
  infrastructure scripts through GitHub Actions instead of manual SSH steps.
- `pay-wireguard-config.yml`: the workflow now opens a temporary SSH rule for
  the GitHub runner CIDR on `opale-pay-secgroup`, applies WireGuard, verifies
  IFK reachability, and removes the rule in cleanup.
- `infra-pay`: added `deploy_ssh_cidr` so product CI can deploy over the
  standard hardened SSH port without owning OpenStack security-group logic.

### Security

- Container deployment requires immutable `ghcr.io/...@sha256:...` refs and a
  read-only GHCR token supplied from infrastructure GitHub secrets.
- Replacing the Vault VM destroys the TPM-sealed master key: the apply and
  delete paths are gated behind explicit confirmations, and the migration
  runbook (README "Vault VM Migration") requires verified backups first.

### Operational Notes

- Next `terraform apply` on `infra-vault` will plan a **replacement** of
  `opale-vault-prod` (image change). Follow the migration runbook.

## [internal-2026-07-05] - 2026-07-05

### Added

- `edge-oracle/`: shared Oracle public proxy owned by infrastructure — custom
  Caddy build with Coraza WAF (OWASP CRS), versioned routes for
  `core.gmlabs.ch`, strict method/content-type guards on wallet auth endpoints,
  shared Docker network `opale-edge`.
- `edge-oracle-deploy.yml`: push-based build and deploy workflow for the edge
  proxy (GHCR image `opale-oracle-edge`).
- `docs/vault-backend-startup.md`: Vault backend startup notes.
- `AGENTS.md` and this `CHANGELOG.md` per Opale shared governance.

### Changed

- README documents the edge-oracle scope and the stock-Caddy limitation for
  product repos (security headers only until the shared proxy runtime is
  infrastructure-owned).

### Security

- WAF enforcement (`SecRuleEngine On`) at the public edge; security headers
  (HSTS, nosniff, frame deny, referrer/permissions policy) applied to all
  routed frontends.

### Operational Notes

- Deploying product frontends on Oracle now requires the `opale-edge` network,
  created by the edge-oracle deploy. Deploy edge-oracle before any frontend.

## [internal-2026-06] - 2026-06

### Added

- Terraform stacks `infra-vault/`, `infra-pay/`, `infra-data/` with cloud-init
  hardening baseline, VPS control workflows, and remote state conventions.
