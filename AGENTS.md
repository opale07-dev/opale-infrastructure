# Opale Infrastructure Agent Instructions

This repository is the canonical provisioning and deployment-owned
configuration layer for Opale VMs and the public Oracle edge. Treat it as
security-sensitive.

## Ownership And Boundaries

This repository owns:

- Terraform stacks for Opale VMs (`infra-vault/`, `infra-pay/`, `infra-data/`);
- first-boot hardening via `cloud-init` templates;
- the shared Oracle public edge (`edge-oracle/`): Caddy + Coraza WAF build,
  reverse proxy routes, WAF policy, shared Docker network `opale-edge`;
- push-based deployment workflows for infrastructure artifacts.

This repository does not own:

- product code, tests, or product container builds (product repos own those);
- application secrets (never store long-lived secrets here);
- product frontend deployment logic.

## Non-Negotiable DevOps Doctrine

Read `_opale-platform/docs/practices/opale-devops-doctrine.md` before any
deployment design change. Key rules:

- Product VMs stay passive. No periodic pull-based deployment loop, no cron or
  `systemd timer` fetching application updates.
- CI/CD pushes deployments explicitly.
- `cloud-init` is first-boot bootstrap only.
- Oracle edge configuration lives here, never in product repos.

## Conventions

- VM: `opale-<service>-<env>`; security group: `opale-<service>-secgroup`;
  app dir: `/opt/<service>`; state key: `<env>/<service>/terraform.tfstate`.
- Commits: `<scope>: <imperative summary>` (e.g. `edge-oracle: tighten WAF
  policy for pay routes`).
- Update `CHANGELOG.md` for every change that alters deploy behavior.
- Validate proxy configuration before reload; healthcheck after deploy.

## Governance

Follow the shared Opale governance (repo structure, logs, commits, changelog,
security baseline) defined in the `opale-infrastructure` skill and
`_opale-platform`. Every new scope in this repo must ship with README coverage
and a CHANGELOG entry — no exceptions.
