# edge-oracle

Shared Oracle public edge for Opale frontends.

This scope is owned by `opale-infrastructure`, not by product repositories.

It is responsible for:

- building the shared Caddy runtime with the Coraza module;
- versioning the public reverse proxy routes and WAF policy;
- exposing the shared Docker network `opale-edge` for frontend containers;
- validating proxy configuration before restart;
- deploying the Oracle edge in a push-based workflow.

It is not responsible for:

- building or deploying product frontend containers;
- pulling product repositories from the Oracle VM;
- embedding product deployment logic in the edge host.

## Current contract

- Shared public proxy container: `opale-oracle-edge-proxy`
- Shared external Docker network: `opale-edge`
- Current routed frontend containers:
  - `/vault` and default route: `opale-vault-frontend`
  - `/pay`: `opale-pay-frontend`
- Public hostname: `core.gmlabs.ch`

## Required GitHub Secrets

- `ORACLE_VPS_IP`
- `ORACLE_SSH_KEY`

The workflow currently assumes SSH access on port `2222` with user `ubuntu`,
matching the existing Oracle host bootstrap.
