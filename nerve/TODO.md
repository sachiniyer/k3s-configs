# nerve — remaining work

State as of **2026-09-20 ~02:15 PDT**. Read `PLAN.md` for the why and
`LOGINS.md` for credential state. This file is the "what is left".

---

## ⭐ START HERE — the two things that matter

### 1. Proton Mail infrastructure (not started)

Everything else for mail is done; Proton is the last mailbox. **Sachin is
standing by to do the interactive login once the container is running** — he
cannot do anything until it is.

**What is known** (surveyed from the Bridge already running on his laptop, so
do not re-derive it):

- Bridge **v3.26.0**, running there as `protonmail-bridge-core --noninteractive`
  under a systemd user unit.
- Keychain helper is **`pass-app`** — GPG-file-based, *not* a D-Bus keyring
  daemon. **This is the finding that makes headless containers viable**; it was
  the main open risk and it is cleared.
- State lives in `~/.config/protonmail`, `~/.local/share/protonmail`, and the
  `pass` store. Mounting **`/root`** on one PVC covers all three.
- Use **`shenxn/protonmail-bridge`** (246 commits, multi-arch, `deb` and
  `build` tag families) rather than building an image. Pin by digest.
  Init flow is `docker run --rm -it -v protonmail:/root shenxn/protonmail-bridge init`
  → interactive CLI → `login` → `info` (prints the generated credentials) → `exit`.
  In k8s this becomes `kubectl exec -it` into the container.
- Ports: IMAP **143**, SMTP **25** inside the container.

**Do NOT lift the laptop's vault.** `vault.enc` is encrypted against a key in
his `pass` store; copying it means copying the GPG key too, and leaves two
Bridge instances sharing one authenticated session — which works right up until
Proton invalidates one. A fresh login in the container is correct. Proton
supports multiple Bridge installs.

**Steps:**

1. Add a `proton-bridge` container to the nerve pod (sidecar keeps IMAP on
   `127.0.0.1`, so no network auth is needed between it and nerve). New PVC
   `proton-data` mounted at `/root`, RWO, `rook-ceph-block`, ~5Gi.
2. Cap the logs. His laptop instance has a pile of ~5MB rotated logs; left
   alone they will eat the PVC.
3. Deploy, then **hand Sachin the interactive login** — `kubectl exec -it`,
   `login`, his Proton credentials + 2FA.
4. Run `info` to read back the **Bridge-generated IMAP password**. This is
   *not* his Proton account password.
5. Store it: SSM `/cluster/nerve/PROTON_BRIDGE_PASSWORD` (SecureString, via the
   `--cli-input-json` recipe in `external-secrets/README.md` — never as a shell
   argument). Uncomment the entry already stubbed in `externalsecret.yaml`.
6. Add `proton-data` to `backup-cronjob.yaml`.
7. Prerequisite to confirm with him: Bridge needs a **paid** plan (Mail Plus or
   Unlimited). It does not work on free accounts.

### 2. Signal channel (transport proven, code unwritten)

**Signal is linked and the transport is verified in both directions** — a send
arrived on his phone, and the receive websocket connected and delivered the
inbound envelope. What does not exist is the nerve channel that uses it. Until
it is written, **the agent does not answer on Signal.**

Write `nerve/channels/signal.py` in the fork (`sachiniyer/nerve`, branch
`signal`), then register it.

- `nerve/channels/base.py` defines `BaseChannel`. Required: `name`,
  `capabilities`, `start`, `stop`, `send`. Optional and gated on declared
  capability flags: `send_placeholder`/`edit_message` (STREAMING),
  `send_typing`, `set_reaction`, `send_file`, `send_interaction`.
- Declare `SEND_TEXT | MARKDOWN | SEND_FILES | TYPING_INDICATOR`. **Skip
  STREAMING** — Signal has no message edit, so streaming would mean spamming
  a new message per chunk.
- Read `nerve/channels/telegram.py` as the full reference and `web.py` as the
  minimal one. Upstream also has an `alex/slack-channel` branch — a second
  in-progress channel worth reading.
- Transport, already validated:
  - receive: websocket `ws://127.0.0.1:8080/v1/receive/+14085333563`
  - send: `POST http://127.0.0.1:8080/v2/send` with
    `{"number": "+14085333563", "recipients": [...], "message": "..."}`
- **Allowlist `+14085333563` only.** A Signal message becomes a tool call on
  this cluster.
- Then: rebuild `Dockerfile.k8s`, push, update the digest in `deployment.yaml`,
  enable the channel in the workspace `config/settings.yaml`.
- **Keep the fork delta to this one file + registration + the Dockerfile.**
  Everything else belongs in the workspace repo or `k3s-configs`. The larger
  the delta, the worse every rebase against upstream gets.

---

## Known gaps worth closing

### Workspace push-back (agent memory is not versioned)

The deploy key is **read-only**, so nothing pushes the agent's own writes back
to `sachiniyer/nerve-workspace`. `MEMORY.md` and any skill it authors live only
on the PVC. The backup covers them, but they are not in git and not reviewable.

Closing this needs a read-write credential, which also unlocks nerve's
`propose_config_change` flow — the agent opening a PR to change its own config
instead of editing it. That is the design in `PLAN.md` §2 and it is worth
having. Decide deliberately; read-only was not an oversight.

### No startup assertion (the day's recurring bug)

Three separate times a pod was `1/1 Running`, health-checked green, and
**broken**: a bad Claude token, an entirely ignored config file, and a failed
workspace merge reported as success. Each surfaced only when a human noticed
something odd.

Add a startup check that (a) reads a couple of known config values back out of
`get_config()` and (b) makes one real one-token model call, and **refuses to
report ready if either disagrees**. That converts this whole class of bug from
"discovered days later" into "the rollout failed".

### Mail skill

Not written — waiting on Proton so it can cover both mailboxes. Gmail and
Calendar work today via `gog`; Proton will be `himalaya` against Bridge on
localhost. Follow the shape of `skills/link-payments/SKILL.md`. Start
**read + draft only**; no send, no delete.

### Smaller items

- **Two default StorageClasses** (`local-path` and `rook-ceph-block`) — a PVC
  omitting `storageClassName` binds non-deterministically. Ours are explicit,
  but this is a live footgun cluster-wide. Belongs in the repo-root `TODO.md`.
- **Every other CronJob in the cluster is implicitly Eastern.** Verified: a
  `47 4` schedule fired at `08:47Z`, so the controller runs UTC-4. Only
  `nerve-backup` pins `timeZone`. vaultwarden (04:17), ssm (05:00) and
  upgrade-check are all 3 hours off local. Worth pinning theirs too.
- **Image is 1.07GB**, ~474MB of which is build cache under `/root/.cache`
  that runtime never uses. A cleanup step would roughly halve it.
- **`claude setup-token` expires ~2027-09-20.** The only credential here with a
  clock on it. Put it in a calendar.
- **Re-enable `inbox-processor`** (`*/30`) once mail lands — deliberately
  disabled in `config/cron/jobs.yaml` because it was spinning up 48 agent
  sessions a day against an empty inbox.
- **`--approve` exists on `link-cli spend-request create`**, undocumented. The
  skill forbids it. Do not "discover" it later and think it is useful; it would
  defeat the human-approval gate the entire wallet design rests on.

---

## Do not undo these

Hard-won; each cost real debugging time today.

| Thing | Why |
|---|---|
| `nerve -c "$NERVE_HOME"` in the Dockerfile CMD | Without it the CLI auto-detects `/nerve`, writes config there, and **silently ignores the real config** while looking healthy |
| **No ConfigMap** mounted at `$NERVE_HOME/config.yaml` | `nerve init` owns and rewrites that file; a read-only mount makes it crash with `EROFS`. Settings live in the workspace `config/settings.yaml` |
| `MODE=json-rpc` on the signal sidecar | In `MODE=normal` the receive websocket upgrade fails **silently** — no error, no inbound messages |
| `strategy: Recreate` | Single replica + RWO PVC deadlocks under RollingUpdate |
| Hard `NotIn milstead` node affinity | It is a laptop that suspends; a pod there goes NotReady until physically woken |
| `nerve.sachiniyer.com` absent from `nginx.conf` SNI map | That absence *is* the security control — it keeps the gateway mesh-only. The gateway has **no auth** by deliberate decision |
| Full (not `--depth 1`) workspace clone | Shallow clone + shallow fetch = grafted histories and "refusing to merge unrelated histories" |
| Never pipe a command whose exit status is tested | `if git merge … \| tail` tests `tail`. Cost a silent stale-config start; `docker build \| tail` hid a failed build the same day |
| `gog` keyring set to `file` + `GOG_KEYRING_PASSWORD` | Default `auto` means no keyring in a container: login appears to work, every cron job then silently fails to read the token |
