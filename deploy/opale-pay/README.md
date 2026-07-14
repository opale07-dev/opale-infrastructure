# Opale Pay backend deployment

This directory is the canonical production state for the Pay backend VM.
`pay-app-deploy.yml` copies these files unchanged to `/opt/opale-pay`, writes
the documented runtime env files, loads the selected proxy image, and runs
`deploy.sh`.

The stack contains CLN, LNbits, Postgres, and the L402 proxy. Bitcoin Core is
not part of this stack; it is reached privately at `10.77.0.1:18332` through
WireGuard.

Only port `8080` is published by the stack. OpenStack restricts it to the
Oracle edge CIDR. CLN REST and Postgres remain on the Compose network.
