# S3, backups & restore

Everything stored in S3, how it's organized, retention, and how to restore. **Rule of thumb:**
rotating backups live under a per-service prefix with a 30-day lifecycle; **one-off archives**
(data from a decommissioned service) live under `archive/…`, which **never expires**.

## Managed bucket: `s3://sachiniyer-cluster-backups` (us-east-1)

Private (public access blocked), default **SSE-AES256**, versioning on. Access via scoped IAM user
`cluster-backup` (policy `s3-backup-write`: `PutObject`/`ListBucket` on this bucket only). Two keys:
a k8s Secret `cluster-backup-aws` in the `bitwarden` ns (the CronJob), and `/root/.aws/credentials`
on the tunnel (the timer). **Neither key is in git.**

### Layout & retention
| Prefix | Contents | Producer | Retention |
|---|---|---|---|
| `vaultwarden/<date>/` | Vaultwarden `/data`: `db.sqlite3` (+ `-wal`/`-shm`), `attachments/`, `rsa_key*.pem`, `sends/` | CronJob `vaultwarden-backup` (`bitwarden` ns, daily 04:17) — `bitwarden/backup-cronjob.yaml` | **30 days** |
| `headscale/headscale-<date>.tgz` | headscale `db.sqlite` + `config.yaml` + node keys | systemd `headscale-backup.timer` (tunnel, daily 04:30) — `/usr/local/bin/headscale-backup.sh` | **30 days** |
| `archive/<name>/…` | One-off archives of decommissioned data | manual | **permanent** (no lifecycle rule) |

Lifecycle rules (verified 2026-08-10): `vaultwarden/` → 30d, `headscale/` → 30d. `archive/` is covered
by **no** rule, so it is kept indefinitely.

Current archives:
- `archive/minecraft/minecraft-world-2026-08-10.tgz` — 681M Minecraft world (server torn down 2026-08-10).

### Restore
- **Vaultwarden:** `kubectl -n bitwarden scale deploy/bitwarden-bitwarden-k8s --replicas=0`, then
  `aws s3 sync s3://sachiniyer-cluster-backups/vaultwarden/<date>/ /data/` into the PVC via a temp pod
  mounting `bitwarden-bitwarden-k8s` read-write, then scale back to 1.
- **headscale:** on the tunnel: `systemctl stop headscale`; `tar xzf headscale-<date>.tgz -C /etc/headscale`;
  `systemctl start headscale`.
- **archive/minecraft:** redeploy minecraft, untar the world into its `/data` PVC before first start.
- [ ] **Not yet tested end-to-end** — do a real Vaultwarden restore into a throwaway ns to validate.

### Convention for future teardowns
Decommissioning a service with data worth keeping:
`aws s3 cp <tarball> s3://sachiniyer-cluster-backups/archive/<service>/<name>-<date>.tgz --sse AES256`.
Under `archive/` it never expires. **Never** put one-offs under `vaultwarden/`/`headscale/` — they'd be
deleted in 30 days. New *rotating* backups should get their own prefix + a matching 30d lifecycle rule.

## Auto-upgrade note
Helm charts / image tags are upgraded **manually** (Renovate was evaluated and skipped). Versions are
tracked in `TODO.md` → "Software inventory & upgrade tracking"; upgrade oldest-first, test after each.
Do NOT blind-auto-apply Helm major or stateful-DB upgrades.

## Account-wide S3 inventory (45 buckets, as of 2026-08-10)

`sachiniyer-cluster-backups` is the **only actively-managed** bucket. The rest are old (2020–2023) and are
**cleanup candidates** — left untouched here because some may still serve static sites or be referenced by
DNS/CloudFront. Review one at a time before emptying/deleting.

- **Static-site hosting (verify DNS/CloudFront first):** `sachiniyer.com`, `aboutsachiniyer.com`,
  `{coffee,camera,email,interesting,personal,projects,ec2-dash,trisha,trishasetup}.sachiniyer.com`,
  `synesthesiavisualizer.com` (+`www.`), `2020-05-07-si-website`, `delivery-service-webpage`, `down-page`.
- **`github.sachiniyer.com*` (10 buckets):** per-project site mirrors — likely stale/consolidated.
- **AWS service artifacts (likely safe to prune if the service is gone):** `codepipeline-us-east-1-*`,
  `elasticbeanstalk-us-east-1-*`, `serverlesshello-dev-serverlessdeploymentbucket-*`,
  `sagemaker-studio-*` (2), `auth-at-edge-origin-{public,private}-*`, `cw-syn-results-*` (CloudWatch
  Synthetics), `snslogs1`, `resow-devops-final`, `resume-github.sachiniyer.com`.
- **Project data (check contents before deleting):** `invoice-categorization`(+`-processed`/`-upload`),
  `sachiniyeraifile`, `sparkup-shop`, `synesthesia-visualizer-webpage`.
- **Random-suffix (likely orphaned Amplify/auto-gen):** `pfp2kc-te0y0wb`, `sysltnj-n8kn7ua`.

- [ ] TODO: review + empty/delete the stale buckets above (one at a time, confirm not referenced by DNS/CDN).
