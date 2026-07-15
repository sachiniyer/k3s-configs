# Cluster Cleanup & Maintenance TODO

Goal: get the cluster back to a **clean, self-documenting state where this repo is the
single source of truth**, optimized for long-term stability and low-friction "in-and-out"
project deploys. Ordered by priority. Investigation as of 2026-07-01.

Legend: 🔴 breaks a live service · 🟠 hygiene/drift · 🟢 nice-to-have/long-term

---

## Phase 0 — Active outages (fix first)

- [ ] 🔴 **Recover or remove the `coffeeproject` node.** Kubelet dead since 2026-06-15
      (`NotReady`, `unreachable` taint). This is the root cause of the crabfit/sembox
      outages AND the stalled k3s upgrade (see Phase 4). Needs physical/console access.
      - If gone for good: `kubectl delete node coffeeproject` so workloads reschedule.
- [ ] 🔴 **crabfit-back & sembox-back stuck `Pending`.** RWO Ceph RBD volumes still attached
      to dead `coffeeproject`; old pods stuck `Terminating`. Unblock by force-deleting the
      terminating pods so volumes detach/reattach on a live node (safe since node is truly
      dead, not partitioned). Fixing the node (above) also resolves this.
- [ ] 🔴 **`rook-ceph-osd-2` CrashLoopBackOff on `sey`.** **Root cause: device-name drift, NOT a
      dead disk.** Disk got re-lettered `/dev/sdb` → `/dev/sdc` (healthy, `ceph_bluestore` present,
      no kernel I/O errors); the OSD still points at the now-absent `/dev/sdb`. Ceph `HEALTH_WARN`,
      2/3 OSDs up, 33% undersized but serving (min_size 2). **Recoverable remotely** — reactivate
      osd.2 on its current device and pin to `/dev/disk/by-id/...` so it can't drift again. Do it
      carefully (cluster is degraded); see Hardware section below.
- [ ] 🔴 **`forgejo-runner` CrashLoop (510d).** ~~Regenerate the 40-char registration secret.~~
      **Superseded — forgejo is being torn down (Phase 3). No fix needed; deletion removes it.**
- [ ] 🟠 **Broken certs (READY=False): ~~`forgejo-cert`~~, `meal-finder-front-cert`, `nfty-cert`.**
      Investigate issuance/renewal (likely tied to cert-manager being very old — see Phase 4).
      (`forgejo-cert` is moot — forgejo being torn down, Phase 3.)

## Hardware issues (node & disk level) — assessed 2026-07-01

| Node | Issue | Fix path | Access |
|---|---|---|---|
| `coffeeproject` | **Fully down** — SSH times out, offline in tailscale, kubelet dead. Off or network-dead. | Power on / diagnose console. If gone, `kubectl delete node`. Blocks crabfit/sembox + k3s upgrade. | **Physical** |
| `sey` | **osd.2 down — device drift**, `/dev/sdb`→`/dev/sdc`. Disk healthy, no I/O errors. | Reactivate osd.2 on current device; pin to `/dev/disk/by-id/`. | Remote (careful) |
| `herkimer` | Ceph **mon near low-space warn** — root 63% used / 42G free (Ceph warns <30% free). | Confirm which mon; free some space on the host. | Remote |
| `sey` | Stray `nbd0–15` at 0B — unused network-block devices. | Cosmetic; ignore. | — |

Notes: `herkimer` is `SchedulingDisabled` (cordoned) — its OSD/mon still run, so likely intentional;
confirm it's meant to be cordoned. `milstead` healthy, single 232G disk (fully allocated to root).

### Storage resilience (Path A — accepted 2026-07-01)
Only 3 OSD hosts with `size 3` → survives **one** host/OSD failure online (min_size 2), but **cannot
self-heal** (no 4th failure domain). Keep `size 3 / min_size 2`.
- [ ] 🟠 **Add OSD-down / Ceph-HEALTH alerting → ntfy.** So a first failure gets a push and is fixed
      before a second one blocks I/O. Highest-value cheap win for a remote operator. (Prometheus is
      already deployed — wire a Ceph/`HEALTH_WARN` alert to the `nfty` service.)
- [ ] 🟢 **Path B (deferred, no new hardware):** when next hands-on, carve a ~50–80G partition-OSD
      out of `milstead` root (offline ext4 shrink) and do the same on `coffeeproject` during its
      reinstall → 4–5 failure domains → self-healing. Footprint is small (replicapool ~106G, shrinks
      after teardowns), so a modest partition suffices.

## Phase 1 — Reconcile repo with reality (safe, no cluster changes)

The working tree already diverges from what's committed. Make the repo match live state.

- [ ] 🟠 **Commit the 21 modified files** (mostly `ingress.yaml`s: bitwarden, blog, digits,
      invoice, matomo, resow, sembox, status, tweets, website, wiki, …). Diff each against
      `kubectl get -o yaml` first to confirm the tree matches live before committing.
- [ ] 🟠 **Add the 4 untracked dirs** that are live but never committed:
      `meal-finder/`, `pong-wasm/`, `schwinn/`, `upgrade/`.
- [ ] 🟠 **Rename `crab.fyi/` → `crabfit/`** so the dir matches its namespace (only mismatch).

## Phase 2 — Bring unmanaged services into the repo (or drop them)

Deployed with **no config dir at all** — decide keep+capture or delete. For infra, export live
manifests (`kubectl get ... -o yaml`) into a dir here.

- [ ] 🟠 `rook-ceph` — capture (already an unchecked box in README). Storage backbone; must be in repo.
- [ ] 🟠 `cnpg-system` (CloudNativePG operator) — capture or remove if unused.
- [ ] 🟠 `prometheus-operator` — reconcile with the `prometheus/` dir (separate release).
- [ ] 🟠 `dns` — repo has `add_dns.py` in the sibling repo; capture the in-cluster dns ns.
- [ ] 🟠 `tc-system` — identify what this is; capture or remove.
- [ ] 🟠 `metallb` — deployed as `metallb-system`; confirm `metallb/` dir covers it fully.
- [ ] 🟠 Personal/uncertain: `alexbday`, `backup`, `skypilot-system` — confirm still wanted;
      add config if keeping, else delete (see Phase 3).

## Phase 3 — Delete stale / dead resources (destructive — confirm each)

### Teardown — no longer used (2026-07-01)
Both hold data. **Optional:** take one final S3/local snapshot before deleting (forgejo has a
built-in `forgejo dump`; Baikal = tar the data dir) in case you want it later. Then remove the
**full footprint** for each — namespace, PVCs, Helm release, ingress, cert, DNS, config dir, status entry.
- [ ] 🟠 **`dav` (Baikal)** — no longer used. Footprint:
      ns `dav` · Helm release `baikal` · PVCs `baikal-config` (1Gi) + `baikal-specific` (15Gi, cephfs) ·
      ingress `dav-ingress` (`dav.sachiniyer.com`) · cert `dav-cert` · repo dir `dav/` · DNS `dav`.
- [ ] 🟠 **`forgejo`** — no longer used. Footprint:
      ns `forgejo` · Helm release `forgejo` · StatefulSets `forgejo-0` + `forgejo-postgresql-0` ·
      Deployments `forgejo-memcached` + `forgejo-runner` · PVCs `data-forgejo-0` (10Gi) +
      `data-forgejo-postgresql-0` (10Gi) · ingress `forgejo-http-ingress` (`git.sachiniyer.com`) ·
      cert `forgejo-cert` · repo dir `forgejo/` (+ retire `deprecated/gitea` predecessor) · DNS `git`.
      (Resolves the Phase 0 forgejo-runner crashloop and forgejo-cert failure by removal.)
- [ ] 🟠 **`alexbday`** (`alexbday.sachiniyer.com`) — no longer used. Footprint:
      ns `alexbday` · Deployment `alex-bday` · ingress `alexbday-ingress` · cert `alexbday-cert` ·
      DNS `alexbday`. No PVC, no Helm release, **no repo dir** (unmanaged — nothing to remove from repo).
- [ ] 🟠 **`jupyterhub`** (`hub.sachiniyer.com`) — no longer used. Footprint:
      ns `jupyterhub` · Helm release `jupyterhub` · Deployments `hub`/`proxy`/`user-scheduler` +
      `continuous-image-puller` · StatefulSet `user-placeholder` · PVCs `claim-sachin` (70Gi) +
      `claim-siyer` (70Gi) + `hub-db-dir` (20Gi) — **~160Gi, biggest single reclaim** ·
      ingress `jupyterhub-ingress` · cert `jupyterhub-cert` · repo dir `jupyterhub/` · DNS `hub`.
      **Optional:** copy anything wanted out of the two 70Gi notebook homes before deleting.
- [ ] 🟠 **`rss` (FreshRSS)** (`rss.sachiniyer.com`) — no longer used. Footprint:
      ns `rss` · Helm release `rss` · Deployment `rss-freshrss` · PVC `rss-freshrss` (10Gi) ·
      ingress `rss-ingress` · cert `rss-cert` · repo dir `rss/` · DNS `rss`.
      **Optional:** export OPML (subscription list) first if you may want the feeds later.

### Other stale / dead
- [ ] 🟠 `ctf` namespace — `ubu-bio-systemd-docker` **Pending for 3+ years**, no config. Delete.
- [ ] 🟠 `deprecated/` dir (gitea, nextcloud) — remove from repo; confirm no live namespaces.
- [ ] 🟠 Config dirs with no live deployment: `mariadb/`, `test/` (ns `health`) — confirm & remove.
- [ ] 🟠 Zero-scaled leftovers: `rook-ceph-mon-s`, `rook-ceph-mon-u` (superseded by w/x/y).
- [ ] 🟠 Decide on `minecraft` (scaled `0/0`) — keep at 0, or remove.
- [ ] 🟠 `alexbday`, `backup` (`test-backup`), `debian` — old personal/test workloads; prune if dead.

## Phase 4 — Upgrades & autoupdate (cluster + Helm)

### k3s node upgrades — mechanism exists but is STALLED
- [ ] 🔴 **Unblock the `system-upgrade-controller` rollout.** Version skew (3 nodes `v1.35.5+k3s1`,
      2 nodes `v1.36.2+k3s1`) is a *stalled* upgrade — `agent-plan`/`server-plan` (channel `stable`)
      can't finish because `coffeeproject` is dead and `herkimer` is cordoned. Fix Phase 0 first,
      then the rollout should converge all nodes.
- [ ] 🟢 Pin the SUC channel to a specific version instead of `stable` for predictable, reviewed
      upgrades; keep `upgrade/plan.yaml` as the source of truth and bump it deliberately.
- [ ] 🟢 Set a maintenance window / `drain` options in the plans so upgrades don't surprise you.
- [ ] 🟢 Standardize node OS (mix of Debian 11 bullseye and 12 bookworm) over time.

### Helm releases — all years stale, no automation
Current vs notably old (from `helm list -A`):
`cert-manager v1.12.3` (2025), `prometheus 19.7.2` (2023), `forgejo 0.12.1 / app 1.20.4` (2023),
`jupyterhub 3.0.2` (2023), `kutt 2.10.4`, `matomo 2.1.0`, `mongodb 13.15.4`, `baikal 2.0.10`.
Only `traefik` is current (39.x, 2026-06).
- [ ] 🟠 **Upgrade `cert-manager` first** (v1.12 is far behind and may not fully support k8s 1.36 —
      likely related to the broken certs in Phase 0). Bump in small steps, test issuance.
- [ ] 🟠 Inventory each Helm release: pin exact chart versions in this repo (values.yaml already
      tracked for most), then upgrade oldest-first with a test after each.
- [ ] 🟢 **Autoupdate strategy** — pick a low-touch option:
      - Renovate/Dependabot on this repo to open PRs when charts/images have new versions
        (fits "in-and-out": review a PR, merge, done). Recommended.
      - Or a scheduled `helm-diff`/`nova` CronJob that reports outdated releases to ntfy.
- [ ] 🟢 Track app-image tags (many deployments likely use `:latest` or old pinned tags) —
      surface via the same automation.

## Phase 4b — Backups (offsite to S3)

Current gap: **zero CronJobs, nothing offsite.** Decision (2026-07-01): the only irreplaceable
data left after Phase 3 teardowns is **Vaultwarden** — the big data apps (jupyterhub, rss, dav,
forgejo) are being removed, so the backup surface is tiny. No Velero needed at this scale.

- [ ] 🟠 **Vaultwarden → S3.** Sidecar in the pod (shares the 800Mi RWO PVC): `sqlite3 .backup`
      + tar `/data` (db + attachments + `rsa_key.pem` + `config.json`) → gpg (reuse `pass.gpg` key)
      → S3, daily. S3 lifecycle rule for retention (~30d). Needs: bucket/region + confirm gpg key.
- [ ] 🟠 **Test one real restore end-to-end** — decrypt, load into a throwaway namespace, open the
      app, confirm the vault is intact. An untested backup doesn't count.
- [ ] 🟢 **Tier-2, decide keep-or-skip** (only if you want them): `filebrowser` (64Gi rootdir),
      `kutt` (Postgres link mappings), `matomo` (MariaDB analytics). DB ones = logical dump CronJob → S3.
- [ ] 🟢 Skip entirely: personal projects (regen from repo), `prometheus` (metrics regenerate), static sites.
- [ ] 🟢 Revisit Velero only if the file-based-PVC list grows past ~4 (uniform `velero restore`).

## Phase 4c — Edge / tunnel machine (EC2 `tunnel`, 44.207.151.72)

Public edge: nginx reverse proxy + headscale, fronting the whole setup over tailscale. Single,
non-HA instance — so it's both the SPOF and the thing we're cautious about restarting. Assessed
2026-07-01: healthy (nginx ok, no failed units, disk 58%), but 460d uptime with a big patch backlog.

- [ ] 🟠 **DR: back up headscale state → S3.** SQLite DB + `config.yaml` (node registrations,
      preauth keys, ACLs). Tiny, irreplaceable-ish — losing it means re-registering every node.
      Do it alongside the Vaultwarden backup (Phase 4b). `nginx.conf` is already in the `repo/`.
- [ ] 🟠 **Enable `unattended-upgrades` (security only).** Userspace patches (nginx/openssl/glibc
      libs) apply live with no downtime — closes the 6 pending security updates without a reboot.
      Kernel still waits for a planned restart.
- [ ] 🟠 **Apply pending kernel + glibc updates via stop/start.** 52 updates (incl. ~25 stacked
      kernels + `libc6`) are staged; running kernel `6.5.0-1014-aws` needs a reboot. An EC2
      **stop/start** applies the new kernel and moves to fresh hypervisor hardware.
      ⚠️ **Confirm the public IP is an Elastic IP first** — if `44.207.151.72` isn't an EIP, a
      stop/start changes it and breaks DNS. Plan a low-traffic window: the whole site is dark
      during the restart. Afterward `apt autoremove` the old kernels to reclaim `/boot`.
- [ ] 🟢 **Confirm the instance is reproducible in IaC** (Terraform/cloud-init). If not, capture
      the instance definition so the edge can be rebuilt if lost — not just its nginx config.
- [ ] 🟢 **headscale upgrade v0.20.0 → current — SKIP unless needed.** Working, all peers connected,
      tailscale client 1.82.0 happy against it. 0.20 → 0.23+ has breaking config/DB migrations for
      little upside. Only revisit on a concrete limitation or client-compat break. Pin/document current version.
- [ ] 🟢 Note: memory is tight (924 MB total, ~166 MB free) — don't add workloads to this box.

## Phase 5 — Make new deploys clean & fast ("in-and-out")

- [ ] 🟢 **Create a `_template/` project dir** with the standard set (`deployment.yaml`,
      `service.yaml`, `ingress.yaml`, `cert`, `pass.gpg` placeholder) so a new project is
      copy-rename-edit. Encodes the conventions the repo already follows.
- [ ] 🟢 Document the deploy flow in `README.md`: copy template → `add_dns.py` → apply →
      add to status page. A 5-line checklist.
- [ ] 🟢 Add the new service to the status page + this TODO's inventory as part of the flow.

## Phase 6 — Structural / long-term (from repo README)

- [ ] 🟢 Merge the two repos (`k3s-configs` + `cheap_portable_k3s`/nginx-sync).
- [ ] 🟢 Reconcile README's stale "Put everything in repo" checklist (e.g. `rook-ceph` still unchecked).
- [ ] 🟢 Cluster wiki (`persistent/cluster-wiki`) — keep current with the above.
- [ ] 🟢 Consider a reconciler (Flux/Argo) *only if* the manual `kubectl apply` flow starts causing
      drift again — otherwise it adds ceremony against the "in-and-out" goal. Renovate + this repo
      may be enough.

---

### Notes / current inventory snapshot
- **Nodes:** herkimer (control-plane, cordoned), devocion, milstead, sey healthy; **coffeeproject dead**.
- **~40 app namespaces**, ~24 endpoints on status.sachiniyer.com.
- **Secrets:** per-dir `pass.gpg` (encrypted, committed); plaintext `pass`/`.env` gitignored. Keep as-is.
- **Storage:** Rook-Ceph (RBD + CephFS), 23 PVCs all Bound, no orphans. Currently degraded (OSD-2 down).
- **No CronJobs** exist — no automated backups despite a `backup` namespace; worth revisiting.
