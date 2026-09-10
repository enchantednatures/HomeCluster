# Lakehouse Stack

Trino + Lakekeeper (Iceberg REST catalog) + CloudNative-PG + MinIO, deployed via Flux in the `lakehouse` namespace.

## Components

| Component | Source | Notes |
|---|---|---|
| Lakekeeper | Helm chart 0.12.0 (`lakekeeper` repo) | Iceberg REST catalog, k8s-SA auth enabled, authz backend `allowall` |
| Lakekeeper DB | CNPG cluster `lakekeeper-db` | 1 instance, openebs-hostpath, barman backups to `minio-store` |
| Bootstrap Job | `lakekeeper/bootstrap/` | Bootstraps server + creates warehouse `lakehouse` |
| Trino | Helm chart 1.42.2 (`trino` repo) | Coordinator-only (`server.workers: 0`), iceberg REST catalog |

## Manual MinIO bucket + user setup

The warehouse bucket and credentials are expected to exist in MinIO before the bootstrap Job runs. Using `mc` from any machine with MinIO admin access (endpoint `http://192.168.1.241:9768`):

```sh
mc alias set home http://192.168.1.241:9768 <ROOT_USER> <ROOT_PASSWORD>
mc mb home/lakehouse-warehouse
# dedicated bucket-scoped user (hardening follow-up — current creds are the shared pg-backup-secret keys)
mc admin user add home lakehouse-ro <random-password>
mc admin policy attach home readwrite --user lakehouse-ro
```

Credentials are stored in `kubernetes/flux/vars/cluster-secrets.sops.yaml` as `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` and substituted into both the bootstrap Job and the Trino catalog properties at the Flux layer.

## Bootstrap re-run procedure

The bootstrap Job (`lakekeeper-bootstrap-v7`) is idempotent: it tolerates `400 CatalogAlreadyBootstrapped` on server bootstrap and `409` on warehouse creation.

To re-run:

1. Bump the Job name suffix in `kubernetes/apps/lakehouse/lakekeeper/bootstrap/job.yaml` (`lakekeeper-bootstrap-v7` → `v8`, etc.) — Jobs are immutable, a new name is required.
2. Commit + push; Flux recreates the Job. (Deleting the old Job alone also works — Flux recreates it from git — but the name must still change if the spec changed.)
3. Verify: `kubectl -n lakehouse get job lakekeeper-bootstrap-v8` → `Complete`.

## Authentication wiring (Trino → Lakekeeper)

Lakekeeper runs with `LAKEKEEPER__ENABLE_KUBERNETES_AUTHENTICATION=true` (k8s ServiceAccount tokens validated via TokenReview; no audience requirement). Trino 480 supports only a static bearer token for the Iceberg REST catalog (`iceberg.rest-catalog.oauth2.token` — there is no token-file property).

Wiring:

1. A 1-year bound token for the `lakekeeper` ServiceAccount (the bootstrap admin) is stored SOPS-encrypted in `kubernetes/flux/vars/cluster-secrets.sops.yaml` as `LAKEKEEPER_SA_TOKEN`.
2. `kubernetes/apps/lakehouse/trino/app/helmrelease.yaml` sets `iceberg.rest-catalog.security=OAUTH2` + `iceberg.rest-catalog.oauth2.token=${LAKEKEEPER_SA_TOKEN}` (token refresh disabled — Lakekeeper does not issue tokens).

**Token rotation (expires ~1 year after 2026-09-10):**

```sh
kubectl -n lakehouse create token lakekeeper --duration=8760h
# decrypt cluster-secrets.sops.yaml, replace LAKEKEEPER_SA_TOKEN, re-encrypt (make sops-encrypt), commit, push
```

Hardening follow-ups: dedicated Trino ServiceAccount + Lakekeeper permission grants instead of the admin SA; bucket-scoped MinIO user; MinIO STS enablement for vended credentials.

## Troubleshooting

**Trino 401 MissingAuthorizationHeader on `/catalog/v1/config`** — Trino is not sending a bearer token. Check the live catalog config: `kubectl -n lakehouse get cm trino-catalog -o jsonpath='{.data.lakekeeper\.properties}'` must contain `oauth2.token=eyJ...`. If it shows `${LAKEKEEPER_SA_TOKEN}` unresolved, the key is missing from `cluster-secrets` or the token expired.

**Bootstrap migration race** — Lakekeeper runs DB migrations on startup; the bootstrap Job retries (checkDb + retries) until the server is ready. If the Job fails with connection errors, check `kubectl -n lakehouse logs deploy/lakekeeper` for migration progress and let Flux retry the Job.

**MinIO STS unavailable** — `AssumeRole` returns `InvalidParameterValue` (STS disabled on this MinIO). Vended credentials are disabled (`vended-credentials-enabled=false`, `sts-enabled=false`); static access keys are used in the Trino catalog properties. If STS is enabled later, switch the warehouse storage profile and Trino to vended credentials.

**ServiceEntry / ambient mesh** — `lakehouse` is Istio ambient (`istio.io/dataplane-mode: ambient`). The Kyverno policy `minio-serviceentry-replication` auto-creates the `minio-service-access` ServiceEntry; verify with `kubectl -n lakehouse get serviceentry`. The trino-coordinator pod is mesh-excluded (`istio.io/dataplane-mode: none` label) because the melusine ztunnel crash-loops on ambient kubelet probes.

**Rolling update stuck Pending** — the coordinator runs with node affinity to `work-0*`; a surge pod may fail scheduling while the old pod holds resources. Deleting the old pod (`kubectl -n lakehouse delete pod <old-coordinator>`) lets the rollout proceed.

## Verification one-liners

```sh
flux get kustomizations -A | grep -E 'lakekeeper|trino'      # 4x Ready=True
flux get helmreleases -A | grep -E 'lakekeeper|trino'        # 2x Ready=True
kubectl -n lakehouse exec deploy/trino-coordinator -- trino --execute "SHOW CATALOGS"
kubectl -n lakehouse exec deploy/trino-coordinator -- trino --execute "SELECT * FROM lakekeeper.canary.t"
```
