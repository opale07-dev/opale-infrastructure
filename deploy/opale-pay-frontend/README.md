# Opale Pay frontend deployment

This directory is the canonical production state for the Pay frontend on the
Oracle VPS. The container joins the shared external `opale-edge` network and
is routed under `/pay` by the infrastructure-owned Caddy and Coraza WAF.

The deployment workflow writes `.env` with the selected immutable image and
the current Pay backend URL, then verifies the local frontend, `/pay/`, and
`/pay/api/health` through the shared edge.
