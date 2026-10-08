# Lakehouse Stack

Apache Gravitino (Iceberg REST catalog + REST API/UI) + CloudNative-PG + Rook-Ceph RGW, deployed via Flux in the `lakehouse` namespace.

## Components

| Component | Source | Notes |
|---|---|---|
| Apache Gravitino | Official OCI Helm chart `gravitino-helm` 1.3.11 (image `apache/gravitino:1.3.1`) | REST API + Web UI on 8090, auxiliary Iceberg REST service on 9001 |
| Gravitino DB | CNPG cluster `gravitino-db` | 1 instance, PostgreSQL 16 (`ghcr.io/cloudnative-pg/postgresql:16.9-22`), storage class `ceph-nvme-block`, barman WAL/backups to `minio-store`, nightly `ScheduledBackup` at 03:00 |
| Warehouse bucket | Rook-Ceph RGW bucket `lakehouse-warehouse` | Provisioned declaratively by ObjectBucketClaim `lakehouse-warehouse` (storage class `ceph-bucket-retain`); scoped credentials live in the OBC-generated Secret/ConfigMap of the same name |
| Schema job | `gravitino-schema-v1` Job | Waits for the DB, creates schemas `gravitino` (entity store) and `lakehouse` (Iceberg JDBC catalog), applies the versioned DDL copied from `/opt/gravitino/scripts/postgresql/schema-<version>-postgresql.sql` |
| Bootstrap job | `gravitino-bootstrap-v2` Job | Creates metalake `lakehouse` and catalog `lakehouse` (provider `lakehouse-iceberg`, JDBC backend, warehouse `s3://lakehouse-warehouse/`, S3 endpoint from the OBC ConfigMap) via the Gravitino REST API. Idempotent (GET-before-POST; tolerates 409) |

## Architecture

The auxiliary Iceberg REST service runs embedded in the Gravitino server (`auxService.names: iceberg-rest`) with `catalog-config-provider: dynamic-config-provider`, metalake `lakehouse`, and default catalog `lakehouse`. Catalogs created through the Gravitino API are auto-registered in the IRC and their S3 properties passed through, so no S3 config lives in the Helm values.

In-cluster endpoints:

| Service | URL |
|---|---|
| Iceberg REST (IRC) | `http://gravitino.lakehouse.svc.cluster.local:9001/iceberg` |
| Gravitino API/UI | `http://gravitino.lakehouse.svc.cluster.local:8090` |

Tailscale ingresses expose both: `gravitino` (API/UI, 8090) and `gravitino-iceberg` (IRC, 9001).

Postgres credentials are held in secret `gravitino-db-user` (SOPS-encrypted at `kubernetes/apps/lakehouse/gravitino/db/db-user.sops.yaml`) and consumed by the HelmRelease via `valuesFrom` with a `targetPath`. One caveat from the upstream chart: the JDBC password still materializes in the rendered ConfigMap `gravitino-gravitino-helm` in-cluster, because the chart has no Secret-reference support yet (apache/gravitino PR #11268). That's acceptable for the homelab and tracked upstream.

Flux Kustomization dependency graph:

```
gravitino-db ──► gravitino-schema ──► gravitino (app)
gravitino-warehouse ──► gravitino-bootstrap (depends on gravitino + gravitino-warehouse)
```

## Security

Gravitino runs with the `simple` authenticator, which means anonymous access. Both the admin API/UI (the `gravitino` Tailscale host, 8090) and the Iceberg REST service (`gravitino-iceberg`, 9001) are reachable by any device on the tailnet. The tailnet is the trust boundary here: anyone on it can create and drop metalakes, catalogs, and tables.

Before widening exposure beyond the tailnet, enable OAuth/OIDC on the Gravitino server (Authentik is already available in this cluster) and configure the Iceberg REST clients to match.

The Postgres JDBC password is stored SOPS-encrypted in git and injected via the HelmRelease `valuesFrom`, but the upstream chart still renders it into the ConfigMap (upstream PR #11268). Acceptable for a homelab, tracked upstream.

## Operations

### Bootstrap / schema re-run

Jobs are immutable. To re-run either one, bump the `-v1` suffix in `gravitino/schema/job.yaml` or `gravitino/bootstrap/job.yaml`, commit, and push. Flux recreates the Job with the new name. Verify with `kubectl -n lakehouse get job`.

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
kubectl -n lakehouse get job gravitino-schema-v1 gravitino-bootstrap-v2
kubectl run curl --rm -it --image=curlimages/curl:8.22.0 -n lakehouse -- http://gravitino.lakehouse.svc.cluster.local:8090/health/ready
kubectl run curl --rm -it --image=curlimages/curl:8.22.0 -n lakehouse -- -H 'Accept: application/vnd.gravitino.v1+json' http://gravitino.lakehouse.svc.cluster.local:8090/api/metalakes
kubectl run curl --rm -it --image=curlimages/curl:8.22.0 -n lakehouse -- -H 'Accept: application/vnd.gravitino.v1+json' http://gravitino.lakehouse.svc.cluster.local:8090/api/metalakes/lakehouse/catalogs
```

Note: `exec` into the `gravitino` pod will usually fail because the image is a JDK image without `curl`. Use the Tailscale endpoint or the `kubectl run ... curlimages/curl` form above instead.
