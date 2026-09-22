# nerve — how to change things

A personal agent on the cluster: reachable from Signal, with mail, calendars,
contacts and a human-approved spending wallet.

**New here? Read in this order:** this file (how to change things) →
`TODO.md` (what it can and cannot do, and the "do not undo" list) →
`LOGINS.md` (every credential and how to re-issue it) → `PLAN.md` (why it is
built this way).

Live at `nerve.sachiniyer.com` (mesh-only) and on Signal.

The web UI is an installable PWA — on a phone, "Add to Home Screen" gives it
its own icon and no browser chrome. It is still mesh-only: an installed copy
opens only while the device is on the tailnet, and shows a connection failure
off it. The manifest, icons and service worker live in the fork under
`web/public/`; see `REBASE.md` there.

**This file answers one question: I want to change X — where does that live and
how does it reach the cluster?**

---

## Three repos, three different flows

The most common way to waste time here is editing the right thing in the wrong
place, or the wrong thing in the right place.

| Repo | Holds | How a change lands |
|---|---|---|
| **`k3s-configs/nerve/`** (here) | manifests, backup job, docs | edit → `kubectl apply` |
| **`sachiniyer/nerve-workspace`** (private) | skills, `settings.yaml`, crons, `SOUL.md`, the agent's memory | `git push` → then pull it in (below), no restart needed |
| **`sachiniyer/nerve`** fork, branch `signal` | the Signal channel, `Dockerfile.k8s`, `selfcheck.py` | edit → **`./deploy.sh`** |

### Decision table

| I want to… | Where |
|---|---|
| add or change a skill | workspace repo, `skills/<name>/SKILL.md` |
| change the model, timezone, quiet hours | workspace repo, `config/settings.yaml` |
| add or reschedule a cron job | workspace repo, `config/cron/jobs.yaml` |
| change how the agent behaves generally | workspace repo, `SOUL.md` / `AGENTS.md` |
| add a CLI the agent can use | fork `Dockerfile.k8s`, then `./deploy.sh` |
| change the Signal channel | fork `nerve/channels/signal.py`, then `./deploy.sh` |
| add a secret | AWS SSM, then `externalsecret.yaml` + `deployment.yaml` |
| add a helper script for a skill | workspace repo, `skills/<name>/scripts/` — shebang `#!/usr/local/bin/python3.13` |
| add a volume, resource limit, sidecar | `deployment.yaml` here |

**The agent also edits the workspace repo itself**, and a sidecar pushes its
changes to `main` every ~15 minutes, unreviewed. That is deliberate. It means
**pull before you edit the workspace**, or you will collide with it.

---

## Changing the image

```sh
git clone --branch signal git@github.com:sachiniyer/nerve.git /tmp/nervefork
# …edit…
./deploy.sh /tmp/nervefork
```

`deploy.sh` builds, pushes, reads the digest **back from the registry**, updates
`deployment.yaml`, applies, and waits on the rollout. Do not do this by hand:
forgetting the digest edit leaves the cluster running the **old image while
every sign says the deploy worked**, which is the worst failure shape here.

Commit the digest change afterwards — the script reminds you.

**Rebasing the fork onto upstream:** see `REBASE.md` in the fork. Short version:
only `nerve/config.py` and `nerve/gateway/server.py` are patched (58 additive
lines), every insertion sits beside its Telegram equivalent, and the other
three files are new so they cannot conflict.

## Changing config or a skill

```sh
git clone git@github.com:sachiniyer/nerve-workspace.git /tmp/ws
cd /tmp/ws && git pull          # the agent pushes here too
# …edit…
git commit && git push
kubectl -n nerve rollout restart deploy/nerve     # or, for cron only:
curl -X POST https://nerve.sachiniyer.com/api/cron/reload
```

The pod's initContainer fast-forwards the workspace on every start. **It never
resets** — the agent's own memory lives in that tree and a reset would destroy
it. If it cannot fast-forward it logs a `WARNING` and leaves the tree alone,
which means your change is *not live*. Check:

```sh
kubectl -n nerve logs -l app=nerve -c workspace-clone --tail=5
```

---

## Getting a workspace push into the running pod

No restart required, but it takes three steps and the first one has a trap.

```sh
POD=$(kubectl -n nerve get pod -l app=nerve -o jsonpath='{.items[0].metadata.name}')

# 1. Pull. This MUST run in the workspace-push sidecar, not the nerve
#    container: nerve's image has no ssh binary, so `git fetch` there fails
#    with "cannot run ssh: No such file or directory" and the following
#    `git merge --ff-only` then cheerfully reports "Already up to date"
#    against a stale origin ref. Both containers mount the same PVC.
kubectl -n nerve exec $POD -c workspace-push -- sh -c 'cd /workspace && git fetch origin && git merge --ff-only origin/main'

# 2. Crons, if config/cron/ changed.
#    POST /api/cron/reload

# 3. Skills, if a SKILL.md changed. Descriptions are CACHED in the skills
#    table, and the description is what decides whether a skill loads at all —
#    editing the file alone changes nothing until this runs.
#    POST /api/skills/sync
```

Both endpoints need a bearer token even though the gateway has no password;
mint one from `auth.jwt_secret` in `$NERVE_HOME/config.local.yaml`.

Confirm it landed:

```sh
kubectl -n nerve exec $POD -c nerve -- sh -c 'cd /root/nerve-workspace && git log --oneline -1'
```

## Verifying a change actually took

**This deployment has a documented history of looking healthy while broken** —
four separate instances in one day (see `TODO.md` → "Do not undo these"). A
green pod proves very little.

The self-check catches the two worst cases at rollout: it reads config back out
of the running loader and makes one real model call, and **fails the container**
if either disagrees. So a failed rollout is now informative:

```sh
kubectl -n nerve logs -l app=nerve -c nerve --tail=40 | grep -A10 -i selfcheck
```

For anything it does not cover, verify by **exercising**, not by reading status:

```sh
# config as the process actually sees it — not as the file reads
kubectl -n nerve exec deploy/nerve -c nerve -- python3 -c \
  "import sys;sys.path.insert(0,'/nerve');from nerve.config import get_config;c=get_config();print(c.timezone, c.agent.model)"

kubectl -n nerve exec deploy/nerve -c nerve -- himalaya envelope list -a proton -m Inbox -s 3
kubectl -n nerve exec deploy/nerve -c nerve -- gog gmail messages list "in:inbox" -a sachinjiyer@gmail.com --max 3 -p
kubectl -n nerve exec deploy/nerve -c nerve -- link-cli auth status
kubectl -n nerve exec deploy/nerve -c nerve -- \
  /root/nerve-workspace/skills/calendar/scripts/icloud-calendar calendars
kubectl -n nerve exec deploy/nerve -c nerve -- \
  /root/nerve-workspace/skills/contacts/scripts/icloud-contacts count
kubectl -n nerve logs -l app=nerve -c nerve --tail=200 | grep "Registered channel"
```

**A script that "works" on the laptop but not in the pod is almost always the
interpreter.** `PATH` puts the nerve venv first and the venv has neither
`caldav` nor `icalendar`; skill scripts must use `/usr/local/bin/python3.13`.

---

## Operating

```sh
# stop it entirely (kill switch — PVCs persist, costs nothing)
kubectl -n nerve scale deploy/nerve --replicas=0
kubectl -n nerve patch cronjob nerve-backup -p '{"spec":{"suspend":true}}'

# start it again
kubectl -n nerve scale deploy/nerve --replicas=1
kubectl -n nerve patch cronjob nerve-backup -p '{"spec":{"suspend":false}}'

# roll back an image: previous digests are in this repo's git log
git log -p --follow deployment.yaml | grep -m5 'nerve:phase1@sha256'
```

Four containers: `nerve`, `signal-api`, `proton-bridge`, `workspace-push`.
Restarting the Deployment restarts all four, and `Recreate` + RWO volumes means
a genuine **60–90 second gap** where `nerve.sachiniyer.com` is down. That is
expected, not a fault.

## Cost

Model usage bills against Sachin's **Claude subscription**, the same pool as
interactive Claude Code — so a chatty agent eats personal headroom. The levers,
in `config/settings.yaml`:

- `agent.cron_model` — scheduled work runs on Sonnet, not Opus
- `agent.effort` / `agent.thinking` — `high`, not the `max` that `nerve init` writes
- `agent.max_concurrent` — 4
- **cron frequency** — each firing is a *full agent session*. `inbox-processor`
  was `*/30` (48 sessions/day) and is now daily.

To move to pay-per-token instead: put an `ANTHROPIC_API_KEY` in SSM and rename
the env var in `deployment.yaml`. The SDK prefers it when both are present.
