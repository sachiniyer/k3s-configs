# nerve — state and remaining work

**Status as of 2026-09-20: built, deployed, in use.** Everything below is
optional. Nothing here blocks using the system.

Start with `README.md` — it answers "I want to change X, where does that live".
`PLAN.md` has design rationale, `LOGINS.md` has every credential.

---

## What it can do

| Capability | Access | How |
|---|---|---|
| Chat from a phone | — | Signal, **Note to Self only** |
| Other Signal threads | **read-only** | `skills/signal/scripts/signal-history` |
| Chat / management UI | — | `nerve.sachiniyer.com`, mesh-only, no password, installable as a PWA |
| Gmail | **read + write** (send, label, archive, delete) | `gog gmail` |
| Proton Mail | **read + write** (send, move, delete) | `himalaya -a proton`, via the Bridge sidecar |
| Google Calendar | read | `gog calendar` (4 calendars) |
| Proton Calendar | **read-only** | `skills/calendar/scripts/proton-calendar` |
| iCloud Calendar | **read + write + edit + delete** | `skills/calendar/scripts/icloud-calendar` |
| Contacts | **read + write** (add, edit, delete) | `skills/contacts/scripts/icloud-contacts` (~258) |
| Spending | request, human-approved | `link-cli` (Stripe wallet) |
| Memory | 3 tiers | `MEMORY.md` → `memory/*.md` → `transcripts` (raw sessions) |
| Scheduled work | — | nerve cron, in the workspace repo |

Seven skills: `mail`, `calendar`, `contacts`, `link-payments`, `memory`, plus
nerve's `nerve-workspace` and `nerve-dev`.

### What it deliberately cannot do

Each of these is a decision, not a gap. Do not "fix" one without meaning to.
The list is deliberately SHORT: on 2026-09-20 Sachin asked for the opposite of
caution — "the agent should be able to basically do everything and just be
instructed to be careful instead". Calendar edit/delete and contact writes were
removed from this list then. Do not add a new entry here because a misuse is
imaginable; add one only because he asked for it.

- **Send mail to a third party without showing it first.** Sending itself is
  enabled; mail leaving under Sachin's name gets recipient/subject/body shown
  to him first. His own mailboxes need no confirmation.
- **Spend without approval.** Every Link request needs a tap on his phone.
  `--approve` exists on the CLI and is forbidden in the skill.
- **Touch the cluster.** No kubectl, no ServiceAccount.

### What is impossible on this account

Not a TODO — there is no path.

- **iCloud Reminders.** Apple migrated them to a proprietary format; CalDAV
  returns only a placeholder saying they were "upgraded". No workaround exists,
  so a grocery list cannot live there.
- **iCloud Mail** — no mailbox on the account (IMAP auth fails).
- **Proton Calendar writes** — no API, no CalDAV. Read-only forever.
- **Apple Notes, Photos, Drive** — no open protocol.

---

## memU is GONE (2026-09-20) — do not bring it back

**It was costing real money, silently.** memU needs a raw Anthropic API key;
it cannot use the subscription OAuth token. We fed it one through nerve config
as `anthropic_api_key: ${MEMU_ANTHROPIC_API_KEY}`, deliberately avoiding the
name `ANTHROPIC_API_KEY` so the SDK would not pick it up.

That was not enough, and the reason is worth reading before anyone tries again.
nerve's `_build_env` in `nerve/agent/backends/claude.py` reads
`config.effective_api_key` and injects it as `ANTHROPIC_API_KEY` into the
**Claude Code subprocess** — which prefers it over `CLAUDE_CODE_OAUTH_TOKEN`.
So every agent turn ran on pay-per-token billing. $15 of credits in about a
day, no error, no log line. Checking the container's own environment showed
nothing, because the key only ever appeared in `/proc/<pid>/environ` of the
spawned CLI.

**Subscription-only inference is now a hard requirement**, enforced three ways:

| Guard | Where |
|---|---|
| `_build_env` drops any API key when the OAuth token is set | fork, `backends/claude.py` |
| `MemUBridge.initialize` returns early with no key, instead of using `"placeholder"` and 401ing forever | fork, `memory/memu_bridge.py` |
| selfcheck fails the rollout on a configured key, an env key, or a missing OAuth token | fork, `selfcheck.py` |

`MEMU_ANTHROPIC_API_KEY` is out of the ExternalSecret and the Deployment. The
SSM parameter still exists — **revoke the key at console.anthropic.com**, which
is the thing that actually stops it being usable.

### What memory is now

All of it runs as ordinary agent turns on the subscription, so it costs nothing
beyond the session:

| Tier | What |
|---|---|
| `MEMORY.md` | hot, in every system prompt |
| `memory/*.md` + the `memory` skill | the agent writes and greps these itself |
| `skills/memory/scripts/transcripts` | full-text over nerve's SQLite, no LLM |
| `memory-consolidate`, 23:41 | reads the day, writes what is durable |
| `memory-maintenance`, 05:00 | dedupes, prunes, sharpens what is written |

`memory-maintenance` is an **override** of nerve's built-in job of the same id
in `config/cron/system.yaml`, which called memU tools that no longer exist and
would fail every morning.

The case against memU was already strong before the billing problem: it failed
a trivial recall at 8 items, it 401d silently for the entire life of two
deployments, and `transcripts` covers most of what it was for with verifiable
results. The money is what settled it.

---

## Remaining work, in rough value order

### 0. Known, not yet fixed: the npx CLI cache is still ephemeral

`/root/.npm` is on the container filesystem, so the Claude Code CLI and the
`skills` package are re-fetched from npm on every pod start. It works, but it
makes startup depend on npm being reachable — which `Dockerfile.k8s` was
explicitly written to avoid for everything else. Either bake it into the image
or give `/root/.npm` a volume.

### 0a. `updates-3.26.0.broken` on the proton PVC

~1,500 files left from the earlier libfido2 incident, renamed rather than
deleted. Harmless (the backup skips it) and safe to `rm -rf` whenever convenient.

### 0b. Proton Bridge self-updated again (2026-09-22)

`3.27.0` is sitting in `updates/` on the proton PVC. Mail works right now, and
the container command wipes that directory at start, so it is self-healing on
the next restart — but it will keep happening. Pinning the Bridge version or
disabling its updater would stop the cycle.

### 1. Alerting

Nothing tells anyone if the agent dies. Today you find out by messaging it and
getting no reply. Prometheus is already on the cluster; a probe on
`nerve.sachiniyer.com/health` plus an alert would close it.

### 2. `inbox-processor` is still disabled

Scheduled daily (`13 7 * * *`) but `enabled: false` in the workspace repo's
`config/cron/jobs.yaml`. Sachin wanted to run one by hand and see what it does
against real mail before it runs unattended. **Each firing is a full agent
session billed to his Claude subscription** — it was `*/30` (48/day) before,
which is why it is daily now.

### 3. Image size

1.07GB, of which ~474MB is build cache under `/root/.cache` that runtime never
touches. A prune step would roughly halve it.

### 4. A grocery list needs a different home

Reminders is out (above). Options, none started: a file in the workspace repo
the agent maintains and reports over Signal; Google Tasks (`gog tasks`, already
authorised, but does not surface in iOS Reminders); or a shared note somewhere
with an actual API.

### 5. Smaller

- **Two default StorageClasses** cluster-wide (`local-path` and
  `rook-ceph-block`) — a PVC omitting `storageClassName` binds
  non-deterministically. Ours are explicit. Belongs in the repo-root `TODO.md`.
- **Other CronJobs are implicitly Eastern.** Verified: a `47 4` schedule fired
  at `08:47Z`, so the controller runs UTC-4. Only `nerve-backup` pins
  `timeZone`. vaultwarden (04:17), ssm (05:00) and upgrade-check are all 3
  hours off local.
- **`claude setup-token` expires ~2027-09-20.** The only credential with a
  clock on it. Calendar it.
- **Fork rebase** — see `REBASE.md` in the fork. Zero commits behind today.

---

## Do not undo these

Each cost real debugging time. Most share one shape: **the pod was `Running`,
health checks green, and the system quietly broken.**

| Thing | Why |
|---|---|
| `nerve -c "$NERVE_HOME"` in the Dockerfile CMD | Without it the CLI auto-detects `/nerve`, writes config there, and **silently ignores every setting** while looking healthy |
| **No ConfigMap** at `$NERVE_HOME/config.yaml` | `nerve init` owns and rewrites that file; a read-only mount crashes it with `EROFS`. Settings live in the workspace `config/settings.yaml` |
| `TZ=America/Los_Angeles` on the container | Without it the container is UTC and every tool rendering local time is 7–8 hours off — an answer that looks right and is wrong |
| `MODE=json-rpc` on the signal sidecar | In `MODE=normal` the receive websocket upgrade fails **silently** — no error, no inbound messages |
| Proton Bridge command clears `updates/` at start | Bridge self-updates onto the PVC into a build needing `libfido2.so.1`, which the image lacks; the breakage then survives every restart |
| `strategy: Recreate` | Single replica + RWO PVC deadlocks under RollingUpdate |
| Hard `NotIn milstead` node affinity | It is a laptop that suspends; a pod there goes NotReady until physically woken |
| `nerve.sachiniyer.com` absent from `nginx.conf` SNI map | That absence **is** the security control — it keeps the gateway mesh-only. The gateway has no auth, by decision |
| Full (not `--depth 1`) workspace clone | Shallow clone + shallow fetch = grafted histories and "refusing to merge unrelated histories" |
| Never pipe a command whose exit status is tested | `if git merge … \| tail` tests `tail`. Caused a silent stale-config start; `docker build \| tail` hid a failed build the same day |
| `gog` keyring `file` + `GOG_KEYRING_PASSWORD` | Default `auto` means no keyring in a container: login appears to work, then every cron job silently fails to read the token |
| Signal routes on DESTINATION, not sender | A linked device syncs every message Sachin sends to anyone as `syncMessage.sentMessage` with `source` = his OWN number, so an allowlist checking `source` passes all of them and the agent answers his texts to other people as if they were prompts. Only `destination == own number` is Note to Self. Unrecognised shapes classify as ignore — guessing "this is for me" is what caused the bug |
| `signal.outbound_allowed_numbers` empty | The agent may READ other threads and may write to none of them. Enforced in `send`/`send_file`/`set_reaction`/`send_typing`, not by instruction. Adding a number is the approval step |
| Backup SNAPSHOTS SQLite and STAGES Proton | `nerve.db` is WAL-mode; on 2026-09-22 the db and its wal were copied 13 minutes apart, which restores torn. `aws s3 sync` exits 2 on gpg-agent's sockets even when they are `--exclude`d, which failed every run from 2026-09-21 — after uploading everything, so the data was there and the job was red. And Bridge's multi-GB `gluon/` cache made each run ~20 minutes for data it re-syncs anyway. Restore-tested |
| `selfcheck.py` runs before `nerve start` | Reads config back out of the loader and makes one real model call. It has already caught a missing `link-cli` |
| `nerve-claude` PVC at `/root/.claude` + `CLAUDE_CONFIG_DIR` | The Agent SDK's conversation `.jsonl` transcripts live here and are what a resume reads. nerve keeps the session *mapping* in `nerve-data`, so without this volume the mapping survives a restart and the transcript does not — **every conversation silently reset on every deploy**, the agent answering with the topic but no history. `CLAUDE_CONFIG_DIR` must stay `/root/.claude`: `validate_resume_target` hardcodes `~/.claude/projects` |
| iCloud: `save_event`/`search` only | `event_by_uid` and todo queries return 412/500 on iCloud. `search` needs `expand=True` or recurring events report their creation date |
| Scripts use `/usr/local/bin/python3.13` | `PATH` puts the nerve venv first, and the venv has neither `caldav` nor `icalendar` |
| Use `./deploy.sh`, not manual builds | Forgetting the digest edit leaves the cluster on the **old image while every sign says the deploy worked**. This actually happened: `link-cli` was added to a working copy, never committed, and a later clean-clone rebuild silently dropped it |
