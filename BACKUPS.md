# Backups & auto-upgrade

## Backups (set up 2026-07-15)

Destination: **`s3://sachiniyer-cluster-backups`** (us-east-1) — private (public access
blocked), default SSE-AES256, versioned, 30-day lifecycle (noncurrent 7d).

Credentials: scoped IAM user **`cluster-backup`** (policy `s3-backup-write`: PutObject/
ListBucket on this bucket only). Two access keys: one as k8s Secret `cluster-backup-aws`
in the `bitwarden` ns (for the CronJob), one in `/root/.aws/credentials` on the tunnel
(for the systemd timer). **Never committed to git.**

| What | Where | Schedule | Mechanism |
|---|---|---|---|
| **Vaultwarden** (`bitwarden` ns) | `s3://.../vaultwarden/<date>/` | daily 04:17 | CronJob `vaultwarden-backup` (`bitwarden/backup-cronjob.yaml`); `aws s3 sync` of `/data` (db+WAL, attachments, rsa keys, sends) |
| **headscale** (tunnel) | `s3://.../headscale/headscale-<date>.tgz` | daily 04:30 | systemd `headscale-backup.timer` → `/usr/local/bin/headscale-backup.sh` (tar of db.sqlite + config.yaml + node keys) |

### Restore
- **Vaultwarden:** scale the deployment to 0, `aws s3 sync s3://.../vaultwarden/<date>/ /data`
  into the PVC, scale back up.
- **headscale:** `systemctl stop headscale`, untar into `/etc/headscale/`, `systemctl start`.

### TODO
- [ ] **Test a real restore end-to-end** (Phase 4b) — an untested backup doesn't count.
- [ ] Optional tier-2: matomo (MariaDB dump), kutt (Postgres dump), filebrowser — add
      logical-dump CronJobs if wanted. Skip: prometheus (regenerates), static sites, personal projects.

## Auto-upgrade

- **OS security patches:** `unattended-upgrades` enabled on tunnel + all 5 nodes (auto, no reboot).
  Kernel updates still need a manual reboot window.
- **k3s:** already automated via `system-upgrade-controller` (channel `stable`). TODO: pin to a
  version for predictable, reviewed upgrades.
- **Helm charts / image tags:** upgraded manually (Renovate was evaluated and skipped). Track versions in
  `TODO.md` "Software inventory & upgrade tracking"; upgrade oldest-first, test after each.
- Do NOT blind-auto-apply Helm major upgrades or stateful DB app upgrades — review + test each.
