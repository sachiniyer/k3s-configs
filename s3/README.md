# S3 backup bucket — versioned config (IaC)

Declarative config for the cluster's only managed S3 bucket, **`sachiniyer-cluster-backups`**
(us-east-1, account `351629464041`). These files are the source of truth; apply them to
recreate or reconcile the bucket + its access. Backup contents, retention semantics, and restore
procedures live in [`../BACKUPS.md`](../BACKUPS.md).

| File | What | Apply command |
|---|---|---|
| `lifecycle.json` | Rotate `vaultwarden/` + `headscale/` at 30d; `archive/` untouched = permanent | `aws s3api put-bucket-lifecycle-configuration --bucket $B --lifecycle-configuration file://lifecycle.json` |
| `encryption.json` | Default SSE-AES256 | `aws s3api put-bucket-encryption --bucket $B --server-side-encryption-configuration file://encryption.json` |
| `public-access-block.json` | Block all public access | `aws s3api put-public-access-block --bucket $B --public-access-block-configuration file://public-access-block.json` |
| `versioning.json` | Versioning enabled | `aws s3api put-bucket-versioning --bucket $B --versioning-configuration file://versioning.json` |
| `iam-policy-s3-backup-write.json` | Least-priv policy for the backup writer (PutObject/ListBucket on this bucket only) | see below |

## Recreate from scratch
```sh
B=sachiniyer-cluster-backups
aws s3api create-bucket --bucket "$B" --region us-east-1
aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration file://public-access-block.json
aws s3api put-bucket-versioning --bucket "$B" --versioning-configuration file://versioning.json
aws s3api put-bucket-encryption --bucket "$B" --server-side-encryption-configuration file://encryption.json
aws s3api put-bucket-lifecycle-configuration --bucket "$B" --lifecycle-configuration file://lifecycle.json

# scoped writer identity used by the Vaultwarden CronJob + the tunnel's headscale timer
aws iam create-user --user-name cluster-backup
aws iam put-user-policy --user-name cluster-backup --policy-name s3-backup-write \
  --policy-document file://iam-policy-s3-backup-write.json
aws iam create-access-key --user-name cluster-backup   # -> k8s Secret cluster-backup-aws (bitwarden ns) + tunnel /root/.aws/credentials
```

## Notes
- The access **keys** are NOT in git — only the policy. Keys live as a k8s Secret (`cluster-backup-aws`,
  `bitwarden` ns) and in `/root/.aws/credentials` on the tunnel.
- `archive/` has **no lifecycle rule on purpose** — one-off archives (e.g. the Minecraft world) are kept
  indefinitely. Adding a new *rotating* backup type = new prefix + a new 30d rule here.
- This covers only the managed bucket. The other ~44 legacy account buckets are inventoried (for cleanup)
  in `../BACKUPS.md`; they are not managed here.
