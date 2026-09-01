# headscale (tunnel/edge control plane)

`config.yaml` here is the live config from the tunnel (`/etc/headscale/config.yaml`), captured
2026-08-10. No key material is in it — only paths. Keys/db live on the tunnel and are backed up
daily to S3 (see [`../BACKUPS.md`](../BACKUPS.md)).

**Current version: v0.29.3** (upgraded from v0.20.0 on 2026-08-10).

## Upgrading: you MUST step through minors
headscale **v0.27 enforces a strict sequential upgrade path** (skipping minors is blocked), and
**v0.28 removed migration support for pre-0.25 databases**. The 0.20 → 0.29.3 upgrade was done as:

```
0.21.0 → 0.22.3 → 0.23.0 → 0.24.3 → 0.25.1 → 0.26.1 → 0.27.1 → 0.28.0 → 0.29.3
```

Each step: download the release binary, `systemctl stop headscale`, install to `/usr/local/bin/headscale`,
start, then verify `headscale nodes list` still shows all nodes before proceeding. Back up
`db.sqlite` + `config.yaml` + the old binary first (rollback artifacts on the tunnel are named
`*.pre-upgrade-2026-08-10` and `/usr/local/bin/headscale.v0.20.0`).

## Two traps that WILL bite you

1. **`server_url` must not contain `base_domain`.** 0.23+ refuses to start with
   `server_url cannot contain the base_domain`. Ours was `server_url: tunnel.sachiniyer.com` +
   `base_domain: tunnel.sachiniyer.com`. Fixed by changing **`base_domain` → `mesh.sachiniyer.com`**.
   ⚠️ This changes MagicDNS names (now `<host>.mesh.sachiniyer.com`; previously
   `<host>.cluster.tunnel.sachiniyer.com`). Safe here because the tunnel resolves node names from
   `/etc/hosts`, not MagicDNS.
2. **`tls_cert_path`/`tls_key_path` are REQUIRED.** `server_url` is `https://…:8080` and headscale
   terminates TLS itself. Omitting them makes headscale serve plain HTTP; every client then fails with
   `PollNetMap: … context deadline exceeded` and headscale logs
   *"listening without TLS but ServerURL does not start with http://"*. Nodes stay reachable over
   existing WireGuard sessions, so the site keeps working and it's easy to miss.

## Other notes
- **`derp.update_frequency: 3h`** (was 24h). The 24h value is why the 2026-08-10 outage persisted: the
  DERP map fetch failed once at boot (DNS wasn't up) and wasn't retried for a day, leaving every client
  with no relays. 0.27+ defaults to 3h.
- Paths are **absolute** on purpose. With the old relative paths (`./db.sqlite`, `./headscale.sock`)
  the CLI only worked when run from `/etc/headscale`. Now `headscale nodes list` works anywhere.
- `policy.path: ""` — no ACL policy, so the 0.26 policy-v1→v2 migration was a non-issue.
- `ephemeral_node_inactivity_timeout` is deprecated (warns on start); move to
  `node.ephemeral.inactivity_timeout` when convenient.
- Config drift check: `diff <(ssh tunnel sudo cat /etc/headscale/config.yaml) config.yaml`.
