# Logins — what a human has to do by hand

Every credential the agent needs that **cannot** be created from a script.
These are the interactive steps: browser consent screens, 2FA prompts, QR
scans. Everything else is automated.

Each one is a **one-time** action. The credential lands either in SSM (static)
or on a PVC (mutable), both of which survive pod restarts, rescheduling and
redeploys. You should never be asked to log in twice for the same thing unless
a credential is revoked, expires, or a volume is lost.

**Status legend:** ✅ done · ⬜ not started · 🔶 blocked

---

## ✅ Claude subscription — `CLAUDE_CODE_OAUTH_TOKEN`

Done 2026-09-20. **Expires ~2027-09-20** — put that in a calendar; it is the
one credential here with a clock on it.

- **Get it:** `claude setup-token` (interactive, device-code flow)
- **Store:** SSM `/cluster/nerve/CLAUDE_CODE_OAUTH_TOKEN` (SecureString). Use
  the `--cli-input-json` recipe in `external-secrets/README.md`; never pass a
  token as a shell argument.
- **Apply:** `kubectl -n nerve annotate externalsecret nerve-secrets force-sync=$(date +%s) --overwrite`
  then `kubectl -n nerve rollout restart deploy/nerve`
- **Verify:** a real model call, not a health check —
  ```sh
  kubectl -n nerve exec deploy/nerve -c nerve -- sh -c \
    'curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/v1/messages \
      -H "Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN" \
      -H "anthropic-beta: oauth-2025-04-20" -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"'
  ```
  Expect `200`. A bad token still produces a **healthy-looking pod** — it only
  fails when someone types something. Do not trust `1/1 Running` here.

## ✅ Workspace repo — deploy key

Done 2026-09-20. No expiry.

- Read-only ed25519 deploy key on `sachiniyer/nerve-workspace`, private half in
  SSM `/cluster/nerve/WORKSPACE_DEPLOY_KEY`.
- Scoped to that one repo; it cannot reach anything else in the account, which
  a personal access token could.
- **Limitation:** read-only means the agent cannot push its own memory or
  skills back, and cannot open config-change PRs. Upgrading that needs a
  read-write credential — a deliberate decision, not an oversight.

---

## ✅ Gmail (+ Calendar)

Done 2026-09-20 for **sachinjiyer@gmail.com** via `gog`. Verified reading real
inbox messages and listing 4 calendars, and — the part that matters — the token
**survived a pod restart**.

Uses `gog`, not `himalaya`, after a deliberate decision: gog cannot request
mail-only scopes, so the grant covers Drive, Apps Script, Chat, Classroom and
Contacts as well. That tradeoff was put to Sachin and accepted; it buys Gmail
and Calendar in a single auth. Do not re-litigate it.

The OAuth client JSON is backed up to SSM
`/cluster/nerve/GOOGLE_OAUTH_CLIENT_JSON`, so a lost PVC does not mean
recreating the client in Google Cloud Console.

**The trap that was fixed here:** gog's keyring defaults to `auto`, which in a
container means no keyring at all. It is set to `file`, unlocked by a random
`GOG_KEYRING_PASSWORD` from SSM. Without that the interactive login appears to
work and every non-interactive use — every cron job — silently fails to read
the token.

- **Re-auth if needed** (browserless, since the pod has no browser):
  ```sh
  kubectl -n nerve exec deploy/nerve -c nerve -- gog auth add <email> --remote --step 1
  # open the printed URL, approve, copy the failed 127.0.0.1 redirect URL
  kubectl -n nerve exec deploy/nerve -c nerve -- gog auth add <email> --remote --step 2 --auth-url "<that url>"
  ```
  The OAuth client must be of type **Desktop app** — the redirect uses a random
  loopback port, which a Web application client rejects.
- **Verify:** `gog gmail messages list "in:inbox" -a <email> --max 3 -p` and
  `gog calendar calendars -a <email> -p`. Note `messages list` requires a query
  argument, and the calendar subcommand is `calendars`, not `calendars list`.

## ✅ Proton Mail

Done 2026-09-20 for **sachin@sachiniyer.com**. Verified listing folders and
reading real inbox messages through `himalaya`. Bridge runs as a sidecar;
password in SSM `/cluster/nerve/PROTON_BRIDGE_PASSWORD`, `proton-data` PVC in
the backup set.

**Bridge self-updates and that breaks it.** During the login it updated itself
to 3.26.0 onto the PVC, and that build needs `libfido2.so.1`, which the image
does not carry — so it died with `exit status 127`, and because the update
lives on the volume the breakage survived restarts. The sidecar command now
clears the update directory at start, which makes it self-healing. If Bridge
ever fails to launch, look there first.

Proton has no API; Bridge decrypts locally and re-exposes the mailbox as
IMAP/SMTP on localhost. The loopback hop is plaintext and that is correct —
Bridge holds the TLS session out to Proton.

- **Prerequisite:** ~~paid plan~~ **CONFIRMED paid 2026-09-20** — Bridge is
  supported. (It does not work on free accounts; this is no longer a blocker.)
- **Order matters:**
  1. Deploy Bridge (its own PVC for the account DB + keychain — not yet built)
  2. `kubectl exec` into it and run the interactive login, including 2FA
  3. Read back the **Bridge-generated IMAP password** — this is *not* your
     Proton account password
  4. Put that generated password in SSM `/cluster/nerve/PROTON_BRIDGE_PASSWORD`
  5. Point `himalaya` at `127.0.0.1:1143` (IMAP) / `127.0.0.1:1025` (SMTP)
- **Persistence:** the login lives in Bridge's own volume. Losing that volume
  means redoing step 2, 2FA included.
- **Not doing:** Proton *Calendar*. No API, no CalDAV, and the unofficial
  bridges drive Proton's private internal API — they break without warning,
  which is the opposite of what this deployment is for.

## ✅ Signal

Linked 2026-09-20 as device "nerve" on **+14085333563**, status
`TRUSTED_VERIFIED`. **Transport verified in both directions:** a `POST /v2/send`
arrived on the phone, and the receive websocket connected and delivered the
inbound envelope back.

The agent does **not** answer on Signal yet — the nerve channel
(`nerve/channels/signal.py` in the fork) is still unwritten. The transport
underneath it is known-good, which is the point of having done this first.

- **Re-link if ever needed:** port-forward to the sidecar, open
  `/v1/qrcodelink?device_name=nerve`, scan from Signal →
  Settings → Linked Devices.
- **Do NOT register the number with `signal-cli`.** Registering (as opposed to
  linking) can de-authenticate the Signal app on the phone.
- **Persistence:** account keys live on the `signal-data` PVC. **Never wipe
  it** — that means re-linking.
- **Lock it down:** allowlist your own number only. A Signal message becomes a
  tool call on this cluster.
- **Config:** the sidecar must run `MODE=json-rpc`. In `MODE=normal` the
  websocket upgrade fails silently and inbound messages never arrive.

## ✅ Link (Stripe agent wallet) — `link-cli`

Done 2026-09-20. Scope granted: **`userinfo:read payment_methods.agentic`** —
payments only. Verified surviving a pod restart, and `payment-methods list`
returns the wallet. Skill: `skills/link-payments/SKILL.md` in the workspace repo.

**This is the only credential here that can move money.** Read the controls
before changing anything about it.

- **Re-auth if ever needed:** `link-cli auth login --client-name "nerve (k3s personal agent)" --interval 5`
  from inside the pod. Pass **no** `--source-actions` — those are the
  financial-insights scopes, and omitting them is what keeps this payments-only.
- **Prerequisite:** US consumer Link account. (A Stripe account is only needed
  for the *financial insights* scope — see below.)
- **How it went:** `link-cli auth login` from inside the pod. It prints a
  verification URL and a short phrase; open the URL, sign in to Link, enter the
  phrase to approve. Interactive, once.
- **Persistence:** `LINK_AUTH_FILE=/root/.config/link/auth.json`, on the
  `nerve-tools` PVC — so the login survives restarts. This is already set in
  `deployment.yaml`. `LINK_REFRESH_TOKEN` handles expiry automatically.
- **Verify:** `link-cli auth status`, then `link-cli payment-methods list`.

### What the agent can and cannot do

It requests **one-time-use virtual cards**; your real card number is never
exposed to it or to the seller. Stripe enforces these limits server-side, so
they are not ours to weaken or bypass:

| Control | Limit |
|---|---|
| Per transaction | $500 |
| Per day | $500 |
| Per 30 days | $20,000 |
| Concurrent active requests | 30 |
| Approval window | 10 minutes |
| Credential validity | 12 hours |

**Every purchase requires you to affirmatively approve it** via push
notification in the Link app. The agent cannot spend on its own — it can only
ask. That gate is the whole safety model, and it is why this is reasonable to
wire into an agent reachable from Signal.

### Scope decision to make before the OAuth flow

Link has two capabilities, requested as separate scopes:

1. **Agent payments** — request payment credentials. This is what you asked for.
2. **Financial insights** — read transaction history, balances, and account
   details from connected bank accounts and cards.

They are independent. **Grant only agent payments unless you specifically want
the agent reading your bank transactions**; insights is a much larger data
exposure than a gated $500 spend cap, and it additionally requires a Stripe
account with Financial Connections.

### Writing the skill

`link-cli --llms-full` emits full agent-oriented documentation, and
`link-cli <command> --schema` gives the exact input contract for any command.
Use those to write `skills/link/SKILL.md` rather than guessing flags — and
have the skill state plainly that a spend request is a *request*, so the agent
does not report a purchase as complete before approval lands.

---

## Not a login, but on the same clock

- **Gateway (`nerve.sachiniyer.com`) has no password.** Auth is deliberately
  off; the tailnet is the only boundary. If a second device or person ever
  joins the tailnet, turn on `auth.jwt_secret` + `password_hash`.
- **ghcr package `sachiniyer/nerve` is public** so the nodes can pull it
  anonymously. It contains no secrets — upstream Apache-2.0 code and public
  CLIs — but it is public, so keep it that way.
