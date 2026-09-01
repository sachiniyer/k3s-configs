# Secret management (AWS SSM Parameter Store + External Secrets Operator)

This is how application secrets get into pods. **No plaintext secret is ever
committed to this repo.**

## The chain

```
AWS SSM Parameter Store        source of truth, SecureString, natively versioned
  /cluster/<namespace>/<KEY>
        |
        |  read by IAM user `cluster-external-secrets` (read-only, /cluster/* only)
        v
ClusterSecretStore  aws-ssm    external-secrets/clustersecretstore.yaml
        |
        v
ExternalSecret  <ns>-secrets   <ns>/externalsecret.yaml   (refreshInterval: 1h)
        |
        v
Kubernetes Secret  <ns>-secrets   (created + owned by ESO; do not edit by hand)
        |
        v
Deployment env:  valueFrom.secretKeyRef.{name: <ns>-secrets, key: KEY}
```

Weekly, a separate job snapshots the whole parameter tree to S3 for disaster
recovery — see `external-secrets/ssm-backup-cronjob.yaml` and `BACKUPS.md`.

## Why SSM rather than git-versioned secrets

The requirement was to version secrets *without* the failure mode of "it only
exists in one place", while keeping it hard to make a mistake.

- **Versioned.** Every `put-parameter --overwrite` creates a new version; old
  values stay retrievable (`aws ssm get-parameter-history`). No SOPS/age keys to
  distribute and no risk of committing a plaintext value by accident.
- **Not only on the cluster.** SSM is the source of truth, so wiping a namespace
  loses nothing.
- **Not only on this machine.** Nothing depends on a laptop-local keyring.
- **Not only in AWS either.** The weekly S3 snapshot (different service,
  versioned bucket, write-only credential) is the third copy.

## Current inventory

26 parameters under `/cluster/`:

| Namespace | Keys | Wired up |
|---|---|---|
| `crabfit` | 3 | yes |
| `invoice` | 6 | yes |
| `meal-finder` | 9 | yes |
| `resow` | 4 | yes |
| `sembox` | 3 | yes |
| `kutt` | 1 | **not yet** — see below |

## Versions in play

- External Secrets Operator **v2.10.0** (chart 2.10.0).
- It serves **`external-secrets.io/v1` only**. `v1beta1` manifests are rejected
  outright — if you copy an example off the internet, check the apiVersion first.

## Adding or rotating a secret

Never pass a secret value as a shell argument (it lands in shell history and in
the process list). Write it to a mode-600 file and use `--cli-input-json`:

```sh
umask 077
cat > /tmp/p.json <<'EOF'
{"Name":"/cluster/<ns>/<KEY>","Value":"<the value>","Type":"SecureString","Overwrite":true}
EOF
aws ssm put-parameter --cli-input-json file:///tmp/p.json
shred -u /tmp/p.json
```

Then, if the key is new, add it to `<ns>/externalsecret.yaml`:

```yaml
    - secretKey: <KEY>
      remoteRef:
        key: /cluster/<ns>/<KEY>
```

and apply it: `kubectl apply -f <ns>/externalsecret.yaml`.

Rotation of an *existing* key needs no manifest change — ESO picks up the new
value within `refreshInterval` (1h). Force it immediately with:

```sh
kubectl -n <ns> annotate externalsecret <ns>-secrets force-sync=$(date +%s) --overwrite
```

Note that most apps only read env vars at startup, so also restart the consumer:
`kubectl -n <ns> rollout restart deploy/<name>`.

## Verifying without ever printing a secret

Compare hashes rather than values:

```sh
kubectl -n <ns> get secret <ns>-secrets -o jsonpath='{.data.<KEY>}' | base64 -d | sha256sum
```

To list which keys exist (names are not sensitive):

```sh
kubectl -n <ns> get secret <ns>-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

## Hazards learned the hard way

- **A referenced key that does not exist in the Secret does not fail loudly at
  apply time** — the Deployment applies fine and the *pod* then fails with
  `CreateContainerConfigError`, i.e. the app goes down. Before applying a
  conversion, diff the `secretKeyRef` keys against the live Secret's keys.
- **`ExternalSecret` reports `Ready=True` while still being stale.** Ready means
  "last sync succeeded", not "matches the manifest on disk". After editing an
  `externalsecret.yaml` you must apply it; two keys (`crabfit/DATABASE_URL`,
  `invoice/SALT`) were missing from the live Secret for exactly this reason.
- **A blank `value:` in a repo manifest silently wipes a live value on apply.**
  Several manifests here had secrets stubbed out as `value:` with nothing after
  it. Grep for `^ *value: *$` before applying anything.
- **Every object needs an explicit `namespace:`.** Most manifests in this repo
  omitted it on the Deployment/Service/Ingress, so `kubectl apply` targeted
  `default` and would have created *duplicate* workloads rather than updating
  the real ones. The 8 files converted here were fixed; others may still lack it.
- **Single replica + RWO PVC needs `strategy: Recreate`** or the rollout
  deadlocks. Encoded for `crabfit-back`, `sembox-back`, and `meal-finder/mongodb`.

## Credentials

| IAM user | Purpose | Scope |
|---|---|---|
| `cluster-external-secrets` | ESO reads secrets | read `/cluster/*` |
| `cluster-ssm-backup` | weekly S3 snapshot | read `/cluster/*`, `s3:PutObject` to `ssm/` only |
| `cluster-backup` | vaultwarden/headscale backups | S3 write |

`cluster-ssm-backup` deliberately has **no** `s3:GetObject` and **no**
`ssm:PutParameter`: a leak of that key cannot read prior backups back out and
cannot modify or destroy the live secrets. Policy: `iam/policy-cluster-ssm-backup.json`.

## Still outstanding

- **`kutt/JWT_SECRET`** is in SSM and its `ExternalSecret` syncs, but the running
  Deployment still carries the literal. kutt is Helm-managed and its
  `values.yaml` supports `existingSecret`, so the clean fix is a `helm upgrade`
  — **blocked**, because kutt's images were repointed to `bitnamilegacy/*` with
  `kubectl set image` only. A `helm upgrade` today reverts them to unpullable
  `bitnami/*` refs. Encode `bitnamilegacy` in `kutt/values.yaml` first.
- **`invoice/REACT_APP_TOKEN_COOKIE` is in git history in plaintext**, from before
  this migration. It is *not* a credential: it is a cookie name (28 chars, 13
  distinct, entropy 3.51 — a readable identifier, not a token), and any
  `REACT_APP_*` value is compiled into the browser bundle and therefore public by
  construction. No rotation or history rewrite is warranted. It is kept in SSM
  only so the whole `invoice` env block is managed uniformly.
- The GPG-encrypted `*/pass.gpg` files are the **previous** mechanism. They are
  retained on purpose: they are encrypted (safe in git) and several of them
  (`bitwarden`, `matomo`, `certs`, `prometheus/auth.gpg`) cover secrets that were
  never migrated to SSM. Don't bulk-delete them.
