# nerve — personal agent on the cluster

A conversational agent running as a pod, reachable from Signal, with access to
mail/calendar/cluster tooling, able to run scheduled work and message us
unprompted. Web UI on the mesh for config and management.

Upstream: [ClickHouse/nerve](https://github.com/ClickHouse/nerve) (Apache-2.0),
a self-hosted agent runtime built on the Claude Agent SDK.

**Status:** planning. Nothing deployed yet.

---

## 1. Why this base

Surveyed the field in Sept 2026 (OpenClaw, Hermes, Khoj, nanobot, nanoclaw,
Letta, Eliza, a dozen Agent-SDK bridges). nerve wins on the axes we care about:

- **Maintained by an organisation**, not one person. Apache-2.0. Everything else
  comparable was somebody's side project (0–1 stars) or carried a self-modifying
  skill system / plugin marketplace we explicitly don't want.
- **Claude Agent SDK native.** Backend seam (`nerve/agent/backends/claude.py`)
  wraps `ClaudeSDKClient`; the engine never imports the SDK directly.
- **Skills are Claude SDK format** — `workspace/skills/<id>/SKILL.md` with YAML
  frontmatter, plus optional `scripts/`, `references/`, `assets/`. This is
  exactly the tooling model we want (see §4).
- **Scheduling is first-class** — APScheduler, declarative YAML, hot-reloadable.
- **Small operationally**: single Python process (FastAPI + uvicorn), state in
  SQLite + workspace files. No Postgres, no pgvector, no vector DB required.

Known gaps going in: ~82 stars (young), **no Signal channel**, and **no
Kubernetes or Helm** — upstream generates a Dockerfile via its wizard rather
than committing one. All three are ours to fill.

---

## 2. Repo layout

Three repos, because they have genuinely different lifecycles and different
writers.

| Repo | Holds | Written by | Lifecycle |
|---|---|---|---|
| `sachiniyer/nerve` (fork) | Signal channel, Dockerfile | us, rarely | rebased on upstream |
| `sachiniyer/nerve-workspace` | SOUL.md, TOOLS.md, skills/, config/cron/ | **the agent** + us | synced live |
| `k3s-configs/nerve/` (here) | manifests, config.yaml, External Secrets | us | applied with kubectl |

The workspace has to be its own repo rather than a directory in this one.
nerve git-syncs the workspace, so pointing it at `k3s-configs` would pull every
cluster manifest into the agent's working directory and let it propose changes
to them. Hard no.

**The workspace repo earns its keep beyond tidiness.** nerve supports the
workspace as a *config repo*: with a remote configured, the agent routes changes
to its own config through `propose_config_change` (a PR) instead of editing
files directly, and **lockdown mode** makes that the only possible route. So the
agent cannot silently rewrite its own instructions — every change to its
personality, skills, or schedule is a diff we review. That is a genuinely good
property for something with cluster credentials, and it also means the memory
and skills it accumulates are versioned rather than living unbacked on a PVC.

Set the workspace repo up empty at Phase 1. Migrating a live workspace into git
later means reconciling PVC state against repo state; starting in git is free.

---

## 3. Architecture

One namespace, `nerve`. One Deployment, single replica.

```
                    nerve.sachiniyer.com  (mesh-only, see §6)
                              │
                         traefik ingress
                              │
┌──────────────────────── pod: nerve ─────────────────────────┐
│                             ▼                               │
│  ┌───────────────────┐        ┌──────────────────────────┐  │
│  │ nerve             │        │ signal-api               │  │
│  │ FastAPI + uvicorn │◀──────▶│ bbernhard/               │  │
│  │ Agent SDK engine  │  HTTP  │ signal-cli-rest-api      │  │
│  │ APScheduler       │  :8080 │ MODE=json-rpc            │  │
│  │ :8900 gateway     │        │                          │  │
│  └───────────────────┘        └──────────────────────────┘  │
│    │         │                          │                   │
│  nerve-data  workspace              signal-data             │
│   (PVC)       (PVC, git)              (PVC)                 │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
   proton-bridge (sidecar or own pod)
   IMAP :1143 / SMTP :1025 on localhost
```

Three PVCs, all RWO:

| Volume | Mount | Holds |
|---|---|---|
| `nerve-data` | `/root/.nerve` | SQLite DBs, logs, sessions, PID |
| `nerve-workspace` | `/workspace` | clone of `nerve-workspace` repo |
| `signal-data` | `/home/.local/share/signal-cli` | Signal account keys — **never wipe** |

**`strategy: Recreate`.** Single replica + RWO PVC deadlocks under the default
RollingUpdate (the new pod waits on a volume the old pod holds). Already bit us
on Vaultwarden, prometheus, matomo, and resow mongo.

**Node placement.** Prefer `devocion` or `sey` over `herkimer` — herkimer is the
sole control plane and runs an ingress pod, so rebooting it already blips the
public site. Ceph RWO volumes follow the pod, so this is a soft preference.

---

## 4. Tooling: CLIs and skills, not MCP servers

**Decision: capabilities reach the agent as command-line tools plus skills. No
MCP servers unless there is genuinely no CLI path.**

Rationale: a CLI can be run by hand to see what it does, pinned and versioned
like any other binary, and tested independently of the agent. When something
breaks months from now, `gcalcli agenda` either works or it doesn't, and the
failure is legible without reasoning about a protocol server, its transport, or
its session state. An MCP server is another long-lived process whose failures
are quiet and only observable through the agent. Skills are Markdown — they
diff cleanly in git and are auditable at a glance.

This happens to be exactly how nerve is built, which is a large part of why we
picked it.

### The three layers

1. **Binaries in the image.** Installed in our Dockerfile, pinned by version.
   The agent reaches them through the Agent SDK's built-in `Bash` tool.
2. **`SKILL.md` per capability** in `workspace/skills/<id>/`. Frontmatter
   (`name`, `description`, `version`, `allowed_tools`) plus a body that teaches
   the agent when and how to use the CLI. `description` drives triggering, so it
   gets the care. Non-trivial invocations become `scripts/` in the skill dir —
   a wrapper we can run ourselves, not a prompt the model has to reconstruct.
3. **`TOOLS.md` in the workspace root** — the environment-specific cheat sheet.
   Upstream designed this file for exactly this: host aliases, account names,
   where credentials live. Skills stay generic; TOOLS.md holds what is ours.

### Out-of-the-box capability set

Three things at launch. Everything else waits.

| # | Capability | CLI | Auth path | Notes |
|---|---|---|---|---|
| 1 | **Gmail** | `gog` (Google Workspace CLI) | Google OAuth refresh token | **Upstream already ships this in its image** — likely zero extra work |
| 2 | **Proton Mail** | `himalaya` | Proton Bridge → IMAP `:1143` / SMTP `:1025` | Bridge needs a **paid** plan; first login interactive (2FA), then persists |
| 3 | **Signal** | — (channel, not a CLI) | QR link to existing number | Replaces Telegram entirely — see §7 |

**`gog` was a find, not a plan.** Reading upstream's Dockerfile template
(`nerve/bootstrap.py`) turned up `gog`, a Google Workspace CLI it installs by
default at v0.11.0. If it covers Gmail properly it is the Gmail path for free,
and it probably covers Calendar too, which would pull Phase 4's calendar work
forward. `Dockerfile.k8s` installs both `gog` and `himalaya`; **Phase 1 settles
which does what before either skill is written.**

The original plan was one CLI (`himalaya`) for both mailboxes. That may still
be the better answer if `gog`'s Gmail support is thin — a single skill covering
two accounts is simpler than two skills. Decide by running both by hand.

Deferred, in rough order: Google Calendar (`gcalcli`), Linear, scoped
`kubectl`. Each is its own change with its own skill.

Web (`WebFetch`/`WebSearch`), files, and shell come free with the Agent SDK.

CLI choices are provisional — validate in Phase 1 by running each one by hand
in the image before writing its skill. If `himalaya` can't do Gmail OAuth
cleanly, fall back to a second CLI rather than reaching for MCP.

---

## 4b. Config layering — read this before touching config

Three layers, merged lowest-first: **`settings.yaml` < `config.yaml` < `config.local.yaml`**.

**`nerve init` owns `config.yaml` and `config.local.yaml` in `$NERVE_HOME` and
rewrites both** (the generated gateway `jwt_secret` lands in the latter). So
**neither can be a read-only ConfigMap mount** — init dies with
`OSError: [Errno 30] Read-only file system`.

Our settings therefore live in **`<workspace>/config/settings.yaml`**, the
git-tracked shared layer, which init leaves alone for keys it does not
generate. There is no ConfigMap in this deployment; that is deliberate, and
`deployment.yaml` carries a comment saying so. Do not "fix" it by adding one.

### The trap this cost us (2026-09-20)

Before the read-only mount crashed anything, it did something worse. The CLI
auto-detects its config directory; finding `/root/.nerve/config.yaml`
unwritable it silently chose the **working directory `/nerve`**, wrote its
generated config there, and recorded that choice in a pointer file
`/root/.nerve/config_dir`. Our ConfigMap was then read by nobody.

The pod was `1/1 Running`, health checks green, chat working — while **ignoring
its entire configuration** and running on upstream defaults:
`background_agent_permissions: true` (a permission control we had deliberately
turned off), `thinking`/`effort: max` (the most expensive possible setting, on
the shared subscription pool), `max_concurrent: 32`, and the wrong timezone.

It surfaced only because the agent reported the wrong time in conversation.

**Rule: verify config by reading it back out of the running process**
(`get_config()`), never by checking that the file is mounted or that the pod is
healthy. `Running` is not `configured`.

### Two sibling failures the same day

- **Bad credential, healthy pod.** An invalid `CLAUDE_CODE_OAUTH_TOKEN` logged
  one soft INFO line (`Claude model discovery returned nothing`) and the pod
  went ready anyway. It failed only when a human typed something. A real
  one-token model call is the only honest check.
- **`docker build | tail` reports the pipe's exit status, not docker's.** A
  failed build looked like a success. Keep exit codes unmasked.

All three share a shape: **green status, broken system.** Worth a startup
assertion that reads back a few known config values and makes a live model
call, and refuses to report ready if either disagrees — so a bad rollout fails
the rollout instead of waiting to be noticed.

---

## 5. Configuration

Upstream's config surface is already well-suited:

- `config.yaml` (shareable, committed here) + `config.local.yaml` (secrets,
  gitignored)
- **`${VAR}` interpolation** in any string value — `${VAR}` required,
  `${VAR:-default}` optional. This is the seam for External Secrets: secrets
  land as env vars, config references them, nothing secret is in git.
- Cron lives in `<workspace>/config/cron/jobs.yaml` (ours; nerve never touches
  it) and `system.yaml` (regenerated by `nerve init`).

### Secrets

Same pattern as everything else on this cluster — AWS SSM Parameter Store
(`/cluster/nerve/<KEY>`, SecureString) → External Secrets Operator →
`nerve-secrets` → `secretKeyRef`. Read `external-secrets/README.md` before
adding parameters rather than re-deriving the recipe.

| SSM key | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Model access (see §8) |
| `GOOGLE_OAUTH_REFRESH_TOKEN` | Gmail |
| `PROTON_BRIDGE_PASSWORD` | Bridge-generated IMAP password |
| `NERVE_JWT_SECRET` | Gateway auth (see §6) |
| `NERVE_WORKSPACE_DEPLOY_KEY` | git sync for the workspace repo |

---

## 6. Web UI on the mesh

Expose the gateway at **`nerve.sachiniyer.com`**, mesh-only, following the
existing `wiki.sachiniyer.com` pattern exactly:

- cert-manager `Certificate` against the `letsencrypt-prod-dns` ClusterIssuer.
  DNS-01 means we get a **real cert for a host that is not publicly reachable** —
  which is why this pattern works for mesh-only services.
- traefik `Middleware` for the https redirect, plus an `Ingress` with TLS.
- **Do not add it to the SNI map in `persistent/repo/nginx.conf`.** Absence is
  the security control: names not in that map fall through to the
  `*.sachiniyer.com` wildcard → `100.64.0.3`, reachable only from mesh-joined
  devices. A `curl` returning 000 from off-mesh is correct, not an outage.

This gives us the web composer, cron management, skill editing, and session
history from any mesh device — which is most of the "manage configs and stuff"
requirement, without exposing an agent with cluster credentials to the internet.

**Gateway auth is deliberately off.** nerve supports it (`auth.jwt_secret`,
bcrypt password hashes) and it was raised as defence-in-depth, but the tailnet
has exactly one member and adding a password to a single-user mesh service buys
little for the friction it costs. Decision made 2026-09-20; recorded here so it
is not silently re-litigated.

The consequence to keep in view: **the tailnet boundary is the only control in
front of an agent with shell access.** If a second device or person ever joins
the tailnet, or a mesh-joined device is lost, turning auth on becomes urgent
rather than optional.

---

## 7. Signal

No Telegram. **The web UI is the bring-up harness** — it works out of the box,
we want it anyway (§6), and it lets us validate nerve itself before debugging
our own channel code. Telegram would be a throwaway.

`nerve/channels/base.py` defines a clean `BaseChannel` ABC. Required:
`name`, `capabilities`, `start`, `stop`, `send`. Optional, gated on declared
capability flags: `send_placeholder`/`edit_message` (STREAMING), `send_typing`,
`set_reaction`, `send_file`, `send_interaction`.

For Signal, declare `SEND_TEXT | MARKDOWN | SEND_FILES | TYPING_INDICATOR` and
skip STREAMING — Signal has no message edit, so streaming would mean spamming
messages. Transport is `signal-cli-rest-api` in **`MODE=json-rpc`**: websocket
for receive, `POST /v2/send` for send. `MODE=normal` silently breaks inbound
streaming — the websocket upgrade fails with no error.

Read `nerve/channels/telegram.py` as the reference implementation (it's the
fullest) and `web.py` as the minimal one. Cross-reference
[claude-matrix-bot](https://github.com/marcobockelbrink/claude-matrix-bot),
which already pairs the Agent SDK with a `signal-cli-rest-api` sidecar.

Link by QR (`/v1/qrcodelink`) against the existing number rather than
registering a new one — registering with `signal-cli` can de-authenticate the
phone's app session. Allowlist our number only.

### Fork discipline

Track `upstream/main` on a long-lived `signal` branch, rebased rather than
merged, so our delta stays legible as a patch series. **Keep the delta to
`nerve/channels/signal.py` + its registration + the Dockerfile.** Everything
else — skills, crons, TOOLS.md, config — lives in the workspace or this repo,
not as source edits. The bigger the source delta, the worse every rebase gets.
Offer the channel upstream once it's real; best outcome is deleting the fork.

---

## 8. Auth: the Claude subscription

**Decision: `CLAUDE_CODE_OAUTH_TOKEN`, from `claude setup-token`.** No second
bill. The Claude Agent SDK reads that env var natively, so upstream's
CLIProxyAPI proxy is not involved and must not be — a shim that replays
subscription credentials from a non-native client is the thing that risks the
account. Running the real SDK with a real token is not that.

An earlier draft of this plan specified an API key. That was wrong: it quietly
overrode a stated preference on the grounds that the extra cost was small.
Recording the tradeoff once is right; deciding it unilaterally is not.

The tradeoff, stated once: subscription usage currently draws from the **same
pool as interactive Claude Code**, so a chatty agent eats personal headroom.
The signal that this has become a problem is hitting limits during normal
Claude Code work. If that happens, switching is deliberately a one-line change
— put an `ANTHROPIC_API_KEY` in SSM and rename the env var in
`deployment.yaml`; the SDK prefers it when both are present. At a few dozen
messages a day plus a handful of crons, pay-per-token would be low tens of
dollars a month, which is the number to weigh against the headroom.

`claude setup-token` issues a roughly year-long token — a calendar reminder,
not a silent-expiry bug, but a renewal that has to be remembered. **Note the
expiry somewhere it will be seen.**

---

## 9. Spin up / spin down

- **Down:** `kubectl -n nerve scale deploy/nerve --replicas=0`. PVCs persist.
  This is the kill switch — one command and it stops answering Signal, stops
  running crons, stops costing money.
- **Up:** `--replicas=1`.
- **Cron without a restart:** `POST /api/cron/reload` re-reads `jobs.yaml`,
  `system.yaml`, and the gate-plugins dir against the running daemon. Reloads
  are all-or-nothing; a malformed file returns 400 and leaves the existing
  schedule untouched, so a typo can't wipe our crons.
- **Config changes:** a rollout restart. Cheap, since `Recreate` is already the
  strategy.
- **Cost ceiling:** `agent.max_concurrent` and `agent.max_turns` bound a
  runaway. Keep `cron_model` on Sonnet so scheduled work isn't at Opus prices.

---

## 10. Blast radius

A Signal message becomes a tool call on the cluster. Decide before wiring
`kubectl`, not after.

- **Allowlist the Signal number.** Nothing else talks to it.
- **Start read-only.** Mail read + draft; no send, no delete. No `kubectl` at
  all in Phase 1–3. Widen deliberately, one capability at a time.
- **`allowed_tools` in skill frontmatter** is the per-skill gate. Use it.
- `background_agent_permissions: false` so background sub-agents don't inherit
  Write/Edit/Bash.
- Gateway: mesh-only **and** JWT auth (§6).
- Lockdown on the workspace repo (§2) so the agent proposes config changes
  rather than making them.

---

## 10b. Workspace sync — how config actually reaches the pod

The workspace repo is authored by us and **pulled forward on every pod start**
by the `workspace-clone` initContainer: full clone on an empty PVC, then
`git merge --ff-only origin/main` thereafter.

**`--ff-only`, never a reset.** The agent writes its own `MEMORY.md` and new
skills into this tree, and a hard reset would silently destroy everything it
has learned. A refused fast-forward means the two have genuinely diverged; the
initContainer logs a `WARNING` and leaves the tree alone, which wants a human
rather than a `--force`.

**Known gap:** nothing pushes the agent's own writes back to the repo. Until
that exists, `MEMORY.md` and any skill the agent authors live only on the PVC —
which is why the backup covers `workspace/` even though most of it is in git.
Closing this needs a read-write credential; the current deploy key is read-only
by design.

### Two bugs this cost, both worth remembering

- **Shallow clone + shallow fetch = grafted histories.** `git clone --depth 1`
  followed by `git fetch --depth 1` produces two histories with no common
  ancestor and the merge dies with *"refusing to merge unrelated histories"*.
  The clone is now full; the workspace is a few hundred KB.
- **`if git merge ... | tail -2` tests `tail`, not `git`.** A pipeline reports
  its *last* element's status, so the failed merge above was reported as
  success and the pod started with stale config. Same shape as
  `docker build | tail` earlier the same day. **Never pipe a command whose exit
  status is being tested.**

---

## 10c. State: what persists and why

Three RWO volumes, each with a distinct failure mode. Anything a tool writes
outside these paths is on the container rootfs and dies with the pod.

| Volume | Mount | Losing it costs |
|---|---|---|
| `nerve-data` | `/root/.nerve` | conversation history, sessions, the generated gateway `jwt_secret` — not recoverable elsewhere |
| `nerve-tools` | `/root/.config` | CLI credentials and artifacts — means redoing the interactive Proton/Gmail logins |
| `nerve-workspace` | `/root/nerve-workspace` | the agent's own memory and self-authored skills (the rest is in git) |

`XDG_CONFIG_HOME` / `XDG_DATA_HOME` / `XDG_STATE_HOME` all point inside
`nerve-tools`, so a well-behaved CLI added later (a Linear CLI, say) keeps its
state without another volume. A tool that hardcodes paths elsewhere needs
checking before it is trusted with a credential.

**Backup:** CronJob `nerve-backup`, daily 04:47, all three volumes to
`s3://sachiniyer-cluster-backups/nerve/<date>/`, SSE-AES256, 30-day lifecycle.
Documented in `BACKUPS.md`; the lifecycle rule is in `s3/lifecycle.json` (a
`put` replaces *all* rules, so edit that file rather than adding rules ad hoc).
The `cluster-backup-aws` Secret is copied from the `bitwarden` namespace and is
**not** in git.

---

## 11. Phases

**Phase 1 — base.** Fork. Create the empty workspace repo. Write a Dockerfile
(upstream only generates one via its wizard) with `himalaya` pinned in. Deploy
with the web UI on `nerve.sachiniyer.com`, API key, no mail, no cluster access.
Confirm: it answers, sessions survive a pod restart, a trivial cron fires,
gateway auth works, workspace git-sync works. **Run `himalaya` by hand in the
image before writing any skill.**

**Phase 2 — mail.** Proton Bridge up, one-time interactive login. Gmail OAuth.
One `himalaya` skill covering both accounts, account details in TOOLS.md. Read
+ draft only. First real cron: a morning brief delivered to the web UI.

**Phase 3 — Signal.** Implement the channel, add the sidecar, QR-link the
number. Brief moves to Signal. Web UI stays for management.

**Phase 4 — widen.** Calendar (`gcalcli`), Linear, scoped `kubectl`, send/write
on mail. Each its own change with its own skill.

---

## 12. Build state (2026-09-20)

Repos and manifests exist; nothing is deployed.

| Item | State |
|---|---|
| `sachiniyer/nerve` fork, `signal` branch | done, `Dockerfile.k8s` committed |
| `sachiniyer/nerve-workspace` (private) | done, seeded from the personal template |
| Manifests here | written; **all pass `--dry-run=server`**, every verb `created` |
| `nerve` namespace | created (empty) |
| Image | **built, smoke-tested, pushed** — `ghcr.io/sachiniyer/nerve:phase1` |
| | digest `sha256:3173080e4e23d26e9e7d5b9b44462f9df158cbd31591a1b0b62597b0e2720c5d`, pinned in `deployment.yaml` |
| `/cluster/nerve/WORKSPACE_DEPLOY_KEY` | **done** — read-only deploy key, SSM SecureString v1 |
| `/cluster/nerve/CLAUDE_CODE_OAUTH_TOKEN` | **missing — the one remaining blocker** |

Image smoke test inside the container: `gog v0.11.0`, `himalaya v2.1.0`,
`node v22.23.2`, `gh 2.101.0`, `git 2.47.3`, `nerve` CLI responding, `web/dist`
built. **`himalaya` reports `+gmail` as a compiled-in feature**, so it handles
both mailboxes and the "one skill, two accounts" plan in §4 stands; `gog` stays
in the image as the likely Calendar path.

### Blocking before first deploy

Only one thing, and it needs a human because the flow is interactive:

```sh
claude setup-token          # then store the result:
umask 077
cat > /tmp/p.json <<'EOF'
{"Name":"/cluster/nerve/CLAUDE_CODE_OAUTH_TOKEN","Value":"<token>","Type":"SecureString","Overwrite":true}
EOF
aws ssm put-parameter --cli-input-json file:///tmp/p.json
shred -u /tmp/p.json
```

### On credentials for the workspace repo

GitHub has **no API for minting personal access tokens** — classic or
fine-grained, it is a browser-only flow. So a PAT could not be created for this
automatically.

A **read-only deploy key** was used instead, and it is the better answer
regardless: it is scoped to `sachiniyer/nerve-workspace` alone and cannot read
any other repo, where a PAT carries account-wide reach. The initContainer
clones over SSH with it.

The cost: a deploy key cannot open pull requests. So the config-repo /
`propose_config_change` flow in §2 needs a token when we get to it — a Phase 3
decision, not a Phase 1 one. Until then the agent can read its workspace and
write to the PVC, but its changes are not pushed anywhere.

### Cluster issue noticed in passing

**Two StorageClasses are marked default** — `local-path` and `rook-ceph-block`.
A PVC that omits `storageClassName` binds non-deterministically. Ours set it
explicitly so they are unaffected, but this is a live footgun for anything that
doesn't. Worth an entry in `TODO.md`.

---

## 13. Open questions

- [ ] Does `gog` cover Gmail (and Calendar) well enough to be the mail path, or
      does `himalaya` handle both mailboxes? §4.
- [x] ~~Does `nerve init` run non-interactively?~~ Yes —
      `nerve init --if-needed --non-interactive` is upstream's Docker path and
      is a no-op once the install is not fresh. The image runs it before
      `nerve start -f`.
- [x] ~~Deploy key or PAT for workspace sync?~~ PAT over HTTPS, as `GH_TOKEN`,
      which `gh` also uses for config-change PRs.
- [ ] Does nerve keep the workspace repo in sync on its own once a remote is
      configured, or does the initContainer clone need a companion sync loop?
      Phase 1 answers this; the clone is one-shot today.
- [ ] Proton Bridge as a sidecar or its own Deployment? Sidecar keeps IMAP on
      localhost (no auth needed); separate is easier to restart independently.
- [ ] Confirm the timezone. Evidence says `America/Los_Angeles` (shell reports
      `-07:00`, headscale relay is `lax`); `configmap.yaml` and `USER.md` still
      say `America/New_York` / TODO because it was inferred, not stated. It
      drives every cron schedule.
- [ ] Keep or trim nerve's ~30-tool internal MCP server (tasks, memory, skills,
      notifications)? It's nerve's own, not third-party, so §4 doesn't
      automatically rule it out.
- [ ] Backup `nerve-data` into `s3://sachiniyer-cluster-backups` alongside
      Vaultwarden and headscale. The workspace is already covered by git.

---

## References

- Upstream docs to read before starting: `docs/architecture.md`,
  `docs/config.md`, `docs/cron.md`, `docs/setup.md`, `docs/sdk-sessions.md`
- `wiki/` in this repo — the mesh-only ingress pattern to copy
- `external-secrets/README.md` — secret plumbing
- `TODO.md` "⭐ START HERE" — cluster open items
