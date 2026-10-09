# Lakehouse Stack

Apache Gravitino (Iceberg REST catalog + REST API/UI) + CloudNative-PG + Rook-Ceph RGW, deployed via Flux in the `lakehouse` namespace.

## Components

| Component | Source | Notes |
|---|---|---|
| Apache Gravitino | Official OCI Helm chart `gravitino-helm` 1.3.11 (image `apache/gravitino:1.3.1`) | REST API + Web UI on 8090, auxiliary Iceberg REST service on 9001 |
| Gravitino DB | CNPG cluster `gravitino-db` | 1 instance, PostgreSQL 16 (`ghcr.io/cloudnative-pg/postgresql:16.9-22`), storage class `ceph-nvme-block`, barman WAL/backups to `minio-store`, nightly `ScheduledBackup` at 03:00 |
| Warehouse bucket | Rook-Ceph RGW bucket `lakehouse-warehouse` | Provisioned declaratively by ObjectBucketClaim `lakehouse-warehouse` (storage class `ceph-bucket-retain`); scoped credentials live in the OBC-generated Secret/ConfigMap of the same name |
| Schema job | `gravitino-schema-v1` Job | Waits for the DB, creates schemas `gravitino` (entity store) and `lakehouse` (Iceberg JDBC catalog), applies the versioned DDL copied from `/opt/gravitino/scripts/postgresql/schema-<version>-postgresql.sql` |
| Bootstrap job | `gravitino-bootstrap-v3` Job | Authenticates to Gravitino via Authentik OIDC, then performs the phase-1 RBAC migration (creates users `akadmin`/`gravitino-service`, group `Gravitino Admins`, and assigns the group as metalake owner) and creates metalake `lakehouse` and catalog `lakehouse` (provider `lakehouse-iceberg`, JDBC backend, warehouse `s3://lakehouse-warehouse/`, S3 endpoint from the OBC ConfigMap) via the Gravitino REST API. Idempotent (GET-before-POST; tolerates 409) |

## Architecture

The auxiliary Iceberg REST service runs embedded in the Gravitino server (`auxService.names: iceberg-rest`) with `catalog-config-provider: dynamic-config-provider`, metalake `lakehouse`, and default catalog `lakehouse`. Catalogs created through the Gravitino API are auto-registered in the IRC and their S3 properties passed through, so no S3 config lives in the Helm values.

In-cluster endpoints:

| Service | URL |
|---|---|
| Iceberg REST (IRC) | `http://gravitino.lakehouse.svc.cluster.local:9001/iceberg` |
| Gravitino API/UI | `http://gravitino.lakehouse.svc.cluster.local:8090` |

Tailscale ingresses expose both: `gravitino` (API/UI, 8090) and `gravitino-iceberg` (IRC, 9001).

Postgres credentials are held in secret `gravitino-db-user` (SOPS-encrypted at `kubernetes/apps/lakehouse/gravitino/db/db-user.sops.yaml`) and consumed by the HelmRelease via `valuesFrom` with a `targetPath`. One caveat from the upstream chart: the JDBC password still materializes in the rendered ConfigMap `gravitino-gravitino-helm` in-cluster, because the chart has no Secret-reference support yet (apache/gravitino PR #11268). That's acceptable for the homelab and tracked upstream.

The server fetches JWKS and the bootstrap Job fetches tokens via the in-cluster service URL (`http://authentik-server.authentik.svc.cluster.local/...`), because the split-DNS internal HTTPS path for `auth.${SECRET_DOMAIN}` currently serves an expired certificate; the public `authority` is still used for the browser flow and issuer validation.

Flux Kustomization dependency graph:

```
gravitino-db ──► gravitino-schema ──► gravitino (app)
gravitino-warehouse ──► gravitino-bootstrap (depends on gravitino + gravitino-warehouse)
```

## Security

Gravitino authenticates via Authentik OIDC (issuer `https://auth.${SECRET_DOMAIN}/application/o/gravitino/`, provider `gravitino`, public client). The web UI (the `gravitino` Tailscale host, 8090) redirects to Authentik for login; service-to-service callers use the OAuth2 client credentials grant with the `gravitino-service` service account's app-password. Anonymous access is disabled.

RBAC (`authorization.enable: true`) is active with service admins `akadmin,gravitino-service`. The `Gravitino Admins` group owns the metalake and is the group used to grant access. See Operations for the two-phase migration the bootstrap Job performs.

The Tailscale hosts still front both services: `gravitino` (API/UI, 8090) and `gravitino-iceberg` (IRC, 9001). OIDC protects the Gravitino server, so the trust boundary is now Authentik rather than the tailnet.

The Postgres JDBC password is stored SOPS-encrypted in git and injected via the HelmRelease `valuesFrom`, but the upstream chart still renders it into the ConfigMap (upstream PR #11268). Acceptable for a homelab, tracked upstream.

## Operations

### Bootstrap / schema re-run

Jobs are immutable. To re-run either one, bump its version suffix (`-v1` in `gravitino/schema/job.yaml`, `-v3` in `gravitino/bootstrap/job.yaml`), commit, and push. Flux recreates the Job with the new name. Verify with `kubectl -n lakehouse get job`.

### RBAC migration (two phases)

Gravitino 1.3.1 treats metalakes created before authorization was enabled as ownerless, so authorization is rolled out in two phases:

1. **Phase 1 (current).** `additionalConfigItems` sets `gravitino.authorization.impl` to `org.apache.gravitino.server.authorization.PassThroughAuthorizer`, which does not enforce authorization. The bootstrap Job creates the `akadmin` and `gravitino-service` users, the `Gravitino Admins` group, and assigns that group as the metalake owner, so ownership is recorded while requests are still permitted.
2. **Phase 2 (enforce).** Once ownership is in place, remove the `additionalConfigItems` block from `kubernetes/apps/lakehouse/gravitino/app/helmrelease.yaml` so Gravitino falls back to its default authorizer and starts enforcing. Bump the bootstrap Job `-vN` suffix if the migration needs replaying.

The service account's app-password lives in the SOPS-encrypted Secret `gravitino-oidc` in the `lakehouse` namespace; the same value is embedded in the Authentik blueprint `blueprint-gravitino.sops.yaml` (token `gravitino-service-token`).

### Known upstream caveats

- No automatic schema initialization for an external Postgres (#9013 / #11099). Handled here by the schema Job.
- The chart no longer touches the postgres schema when `postgresql.enabled=false`, which avoids a CNPG incompatibility (#11696).
- Chart/image path changed in 1.3.0 (#11267). Do not run pre-1.3.0 images with this chart.

### Durability and backups

Only the Gravitino entity-store Postgres is backed up: a nightly `ScheduledBackup` plus barman WAL to `minio-store`. Backups accumulate with no retention policy configured on the shared `minio-store` ObjectStore.

The warehouse bucket `lakehouse-warehouse` (Iceberg data and metadata) has no backup or versioning. The `ceph-bucket-retain` storage class only prevents bucket deletion when the ObjectBucketClaim is removed; it is not data-loss protection. Accepted RPO for warehouse data is currently zero (no copy exists).

OBC edge case: the bucket name is fixed and the storage class is Retain, so deleting and re-creating the ObjectBucketClaim can fail with "bucket already exists" until the retained bucket is manually removed or the claim is reconciled.

### Migration note

Lakekeeper, Trino, and the MinIO warehouse credentials were removed from this repo. Catalog metadata was NOT migrated (fresh start). The old MinIO bucket is left untouched; the new warehouse bucket is on Ceph RGW.

## Troubleshooting

**Helm chart won't pull the OCI chart.** Check the HelmRepository `gravitino` in `flux-system`:

```sh
flux -n flux-system get helmrepository gravitino
```

If it isn't Ready, the OCI URL or the chart tag is wrong; the URL points at `oci://registry-1.docker.io/apache` and Flux appends the chart name `gravitino-helm`.

**Schema job failing or pending.** Check the Job logs and the DB cluster:

```sh
kubectl -n lakehouse logs job/gravitino-schema-v1
kubectl -n lakehouse get cluster gravitino-db
```

If the CNPG cluster isn't ready, the schema Job stays pending waiting for the database. Fix cluster readiness first, then bump the Job suffix to re-run.

## Verification one-liners

```sh
flux get kustomizations -A | grep gravitino         # 5x Ready=True
flux get helmreleases -A | grep gravitino           # Ready=True
kubectl -n lakehouse get objectbucketclaim lakehouse-warehouse
kubectl -n lakehouse get job gravitino-schema-v1 gravitino-bootstrap-v3
kubectl run curl --rm -it --image=curlimages/curl:8.22.0 -n lakehouse -- http://gravitino.lakehouse.svc.cluster.local:8090/health/ready
```

The API now requires a bearer token. Fetch a machine-to-machine token with the `gravitino-service` service account; the app-password lives in the `gravitino-oidc` Secret:

```sh
APP_PASSWORD="$(kubectl -n lakehouse get secret gravitino-oidc -o jsonpath='{.data.app-password}' | base64 -d)"
# Run from inside the cluster: the public token endpoint is currently affected by an
# Authentik token-issuance latency that can exceed the Cloudflare tunnel timeout (504).
TOKEN="$(curl -sS -X POST 'http://authentik-server.authentik.svc.cluster.local/application/o/token/' \
  -H 'Host: auth.${SECRET_DOMAIN}' \
  -H 'X-Forwarded-Proto: https' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'client_id=gravitino' \
  --data-urlencode 'username=gravitino-service' \
  --data-urlencode "password=$APP_PASSWORD" \
  --data-urlencode 'scope=openid profile email' | sed -nE 's/.*"access_token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
```

Then call the API with it:

```sh
curl -sS -H 'Accept: application/vnd.gravitino.v1+json' -H "Authorization: Bearer $TOKEN" https://lakehouse-gravitino-tailscale-ingress.rya-bebop.ts.net/api/metalakes
curl -sS -H 'Accept: application/vnd.gravitino.v1+json' -H "Authorization: Bearer $TOKEN" https://lakehouse-gravitino-tailscale-ingress.rya-bebop.ts.net/api/metalakes/lakehouse/catalogs
```

The Iceberg REST service is OIDC-protected too, so the IRC clients (Spark, PyIceberg, etc.) need OAuth2 client credentials configured against the `gravitino` provider (`client_id` `gravitino`, username `gravitino-service`, app-password from the `gravitino-oidc` Secret) to obtain tokens for `https://lakehouse-gravitino-iceberg-tailscale-ingress.rya-bebop.ts.net/iceberg`.

Note: `exec` into the `gravitino` pod will usually fail because the image is a JDK image without `curl`. Use the Tailscale endpoint or the `kubectl run ... curlimages/curl` form above instead.
