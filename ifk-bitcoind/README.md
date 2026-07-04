# ifk-bitcoind

Dedicated `bitcoind` runtime for Opale Pay on the IFK VPS.

This host-level service is intentionally separate from the Opale Pay application
VM. Opale Pay and CLN consume it through Bitcoin RPC.

## Network Contract

- `bitcoind` testnet RPC: `18332/tcp`
- `bitcoind` testnet P2P: `18333/tcp`
- Recommended RPC path: WireGuard between `opale-pay-prod` and the IFK VPS
- Do not expose RPC on the public Internet

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
```

`BITCOIN_RPC_USER` and `BITCOIN_RPC_PASSWORD` must match the GitHub secrets used
by the `OpalePay` backend deployment workflow.

## Configure IFK WireGuard

Run from the `opale-infrastructure` checkout on the IFK VPS after creating a
server keypair:

```bash
sudo sh scripts/configure-wireguard.sh \
  --interface wg0 \
  --address "${IFK_WG_ADDRESS}" \
  --private-key "${IFK_WG_PRIVATE_KEY}" \
  --peer-public-key "${OPALE_PAY_WG_PUBLIC_KEY}" \
  --peer-allowed-ips "${OPALE_PAY_WG_ALLOWED_IPS}" \
  --listen-port "${IFK_WG_LISTEN_PORT}" \
  --persistent-keepalive ""
```

Then start `bitcoind` with RPC bound to the IFK WireGuard address:

```bash
docker compose --env-file ifk-bitcoind/wireguard.env -f ifk-bitcoind/docker-compose.yml up -d
```

The Opale Pay VM side is configured by the `Opale Pay - Configure WireGuard`
workflow. It expects:

- `OPALE_PAY_SSH_PRIVATE_KEY`
- `OPALE_PAY_WG_PRIVATE_KEY`
- `IFK_WG_PUBLIC_KEY`
- `IFK_WG_ENDPOINT`, for example `<ifk-public-ip>:51820`
