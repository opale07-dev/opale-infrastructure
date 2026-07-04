# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This project does not publish versioned releases yet; dated internal releases
are used until the first public version.

## [Unreleased]

### Added

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
- `backend-bootstrap-window.yml`: fixed stale `working-directory: ./infra`
  (the stack lives in `./infra-vault`).
- `infra-vault`: `image_id` added to `lifecycle.ignore_changes` so a newer
  `most_recent` Ubuntu image can never trigger an implicit VM replacement
  during routine applies (e.g. SSH window); image migrations must use an
  explicit `terraform apply -replace`.

### Changed

- `infra-vault` migrated from Alpine Linux 3 to Ubuntu LTS minimal per the
  DevOps doctrine (vTPM metadata preserved, config_drive enabled).
- `infra-deploy.yml`: push now runs `terraform plan` only; apply requires a
  manual dispatch with `confirm_replace=opale-vault-prod`.

### Security

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
