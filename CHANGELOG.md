# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This project does not publish versioned releases yet; dated internal releases
are used until the first public version.

## [Unreleased]

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
