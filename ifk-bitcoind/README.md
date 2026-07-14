# ifk-bitcoind

Dedicated `bitcoind` runtime for Opale Pay on the IFK VPS.

This host-level service is intentionally separate from the Opale Pay application
VM. Opale Pay and CLN consume it through Bitcoin RPC.

The canonical deployment path is the GitHub Actions workflow
`IFK - Configure Opale Pay bitcoind` (`.github/workflows/ifk-bitcoind-config.yml`).
Do not hand-edit IFK as the primary path; rerun the workflow after changing
this directory or `scripts/apply-ifk-bitcoind.sh`.

## Network Contract

- `bitcoind` testnet RPC: `18332/tcp`
- `bitcoind` testnet P2P: `18333/tcp`
- Recommended RPC path: WireGuard between `opale-pay-prod` and the IFK VPS
- Do not expose RPC on the public Internet
- Required public IFK ingress: `51820/udp` for WireGuard
- Optional public IFK ingress: `18333/tcp` for Bitcoin testnet peers

Use `BITCOIN_RPC_BIND` to bind RPC to the WireGuard address on IFK, for example
`10.77.0.1`, and `BITCOIN_RPC_ALLOW_IP` to allow only the Opale Pay WireGuard
peer CIDR, for example `10.77.0.2/32`.

## Required Environment

```env
IFK_WG_ADDRESS=10.77.0.1/24
IFK_WG_LISTEN_PORT=51820
IFK_WG_PRIVATE_KEY=<ifk-private-key>
OPALE_PAY_WG_PUBLIC_KEY=<opale-pay-public-key>
OPALE_PAY_WG_ALLOWED_IPS=10.77.0.2/32
BITCOIN_RPC_BIND=10.77.0.1
BITCOIN_RPC_ALLOW_IP=10.77.0.2/32
BITCOIN_RPC_PORT=18332
BITCOIN_RPC_USER=opale_pay_rpc
BITCOIN_RPC_PASSWORD=<strong-secret>
BITCOIN_PRUNE_MB=550
BITCOIN_DB_CACHE_MB=256
BITCOIN_MAX_MEMPOOL_MB=100
BITCOIN_MEMORY_LIMIT=1536m
BITCOIN_P2P_BIND=127.0.0.1
```

`BITCOIN_RPC_USER` and `BITCOIN_RPC_PASSWORD` must match the GitHub secrets used
by the `OpalePay` backend deployment workflow.

The default memory ceiling is 1.5 GiB, with a 256 MiB database cache and a
100 MiB mempool. Testnet P2P is bound to loopback by default. Set
`BITCOIN_P2P_BIND=0.0.0.0` only when inbound peers are explicitly required and
the host firewall has been reviewed.

## Configure IFK

The workflow installs:

- `/usr/local/bin/opale-configure-wireguard`
- `/usr/local/bin/opale-apply-ifk-bitcoind`
- `/etc/opale/ifk-bitcoind.env` (`root:ubuntu 0640`)
- `/opt/opale/ifk-bitcoind/docker-compose.yml`

It then applies WireGuard, opens `51820/udp`, and starts the compose service.

Manual equivalent for emergency use only:

```bash
sudo /usr/local/bin/opale-apply-ifk-bitcoind
```

The compose file publishes RPC only on `BITCOIN_RPC_BIND` (normally
`10.77.0.1`). Do not publish `18332/tcp` on the public IFK interface.

The Opale Pay VM side is configured by the `Opale Pay - Configure WireGuard`
workflow. It expects:

- `OPALE_PAY_SSH_PRIVATE_KEY`
- `OPALE_PAY_WG_PRIVATE_KEY`
- `IFK_WG_PUBLIC_KEY`
- `IFK_WG_ENDPOINT`, for example `<ifk-public-ip>:51820`

The IFK workflow expects:

- `IFK_SSH_PRIVATE_KEY`
- `IFK_WG_PRIVATE_KEY`
- `OPALE_PAY_WG_PUBLIC_KEY`
- `BITCOIN_RPC_USER`
- `BITCOIN_RPC_PASSWORD`
