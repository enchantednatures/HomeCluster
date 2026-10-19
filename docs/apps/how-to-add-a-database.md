# How to Add a PostgreSQL Database to an Application

This guide attaches a CloudNative-PG managed PostgreSQL database to an application as a `db/` component. The reference implementations are `kubernetes/apps/atuin/atuin/` (app plus database) and `kubernetes/apps/immich/immich/` (app plus database, cache, and backups).

## Prerequisites

- The application already exists per [How to Add an Application](how-to-add-an-application.md).
- The `cloudnative-pg` operator Kustomization is deployed (it is part of the operators layer).
- Decisions: the cluster name (convention: `<app>-db`), the database name, and the owner role.
- Optional: an S3-compatible object store if you want the `barman-cloud` plugin to archive backups. The reference apps reference an object store named `minio-store` via `barmanObjectName`.

## What gets created

| File | Resource | Purpose |
|------|----------|---------|
| `db/kustomization.yaml` | Kustomization | Lists the component's resources |
| `db/cluster.yaml` | `postgresql.cnpg.io/v1` Cluster | The PostgreSQL cluster itself |
| `db/database.yaml` | `postgresql.cnpg.io/v1` Database | Declares the application database and owner |
| `db/pooler.yaml` | `postgresql.cnpg.io/v1` Pooler | PgBouncer read-write / read-only endpoints |
| `db/scheduled-backup.yaml` | `postgresql.cnpg.io/v1` ScheduledBackup | Scheduled `barman-cloud` backups |
| `db/podmonitor.yaml` | `monitoring.coreos.com/v1` PodMonitor | Optional metrics scraping |
| `db/*.sops.yaml` | Secrets | Role and superuser credentials |

The component is delivered by a Flux Kustomization that depends on the `cloudnative-pg` operator, and the application's Kustomization depends on the database Kustomization.

## Step 1: Create the db/ directory

```
<app>/db/
├── kustomization.yaml
├── cluster.yaml
├── database.yaml
├── pooler.yaml
├── scheduled-backup.yaml
├── podmonitor.yaml
├── <app>-db-user.sops.yaml
└── <app>-db-superuser.sops.yaml
```

`db/kustomization.yaml`, modeled on `kubernetes/apps/atuin/atuin/db/kustomization.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cluster.yaml
  - podmonitor.yaml
  - database.yaml
  - pooler.yaml
  - <app>-db-user.sops.yaml
  - <app>-db-superuser.sops.yaml
  - scheduled-backup.yaml
```

Adjust the list to the files you create; omit `scheduled-backup.yaml` if you are not using `barman-cloud` backups yet.

## Step 2: Create the credentials

CloudNative-PG reads role passwords from Secrets that must contain `username` and `password` keys. Create `db/<app>-db-user.sops.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/v1/secret.json
---
apiVersion: v1
kind: Secret
metadata:
  name: <app>-db-user
  namespace: <namespace>
type: Opaque
stringData:
  username: <app>
  password: <set-a-strong-password>
```

If you enable superuser access on the Cluster, create the superuser secret the same way (the reference apps name it `superusersecret.sops.yaml` / `postgres-superuser`).

Encrypt both files before committing:

```bash
make sops-encrypt
```

## Step 3: Create the Cluster

`db/cluster.yaml`, modeled on `kubernetes/apps/atuin/atuin/db/cluster.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/cluster_v1.json
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <app>-db
  namespace: <namespace>
  labels:
    app.kubernetes.io/name: <app>-db
spec:
  inheritedMetadata:
    labels:
      istio.io/dataplane-mode: "none"
  # renovate: datasource=docker depName=ghcr.io/cloudnative-pg/postgresql versioning=redhat
  imageName: ghcr.io/cloudnative-pg/postgresql:17.1-1
  instances: 3
  primaryUpdateStrategy: unsupervised
  storage:
    size: 10Gi
    storageClass: ceph-block-ssd
  resources:
    requests:
      memory: "512Mi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1000m"
  enableSuperuserAccess: true
  superuserSecret:
    name: <app>-db-superuser
  postgresql:
    parameters:
      max_connections: "300"
      shared_buffers: 512MB
  monitoring:
    enablePodMonitor: false
  managed:
    roles:
      - name: <role>
        ensure: present
        comment: <App role>
        login: true
        superuser: false
        passwordSecret:
          name: <app>-db-user
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: minio-store
        serverName: <app>
```

Field notes:

- `instances: 3` gives a primary and two replicas; use `1` for less critical apps.
- `storage.storageClass: ceph-block-ssd` matches the cluster's fast block storage.
- `inheritedMetadata` keeps the database pods out of the ambient mesh (`istio.io/dataplane-mode: "none"`), matching the reference apps.
- `managed.roles` creates login roles with passwords from the Secrets you created.
- The `barman-cloud` plugin requires the referenced object store (`barmanObjectName`) to exist. Drop the `plugins` block if you are not configuring object-store backups.
- Immich uses a different `imageName` (`ghcr.io/tensorchord/cloudnative-vectorchord`) because it needs the VectorChord extension; most apps use the stock CloudNative-PG image shown here.

## Step 4: Create the Database, Poolers, and backup schedule

`db/database.yaml`, from `kubernetes/apps/atuin/atuin/db/database.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/database_v1.json
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: <app>-db
  namespace: <namespace>
spec:
  name: <database>
  owner: <role>
  cluster:
    name: <app>-db
```

`db/pooler.yaml` defines PgBouncer endpoints. The reference app declares a read-write pooler; the same file can hold a read-only one:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/pooler_v1.json
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: <app>-db-pooler-rw
  namespace: <namespace>
  labels:
    app.kubernetes.io/name: <app>-db
spec:
  template:
    metadata:
      labels:
        istio.io/dataplane-mode: "none"
  cluster:
    name: <app>-db
  instances: 1
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "1000"
      default_pool_size: "25"
      min_pool_size: "5"
      reserve_pool_size: "5"
  monitoring:
    enablePodMonitor: false
```

`db/scheduled-backup.yaml`, from `kubernetes/apps/atuin/atuin/db/scheduled-backup.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/scheduledbackup_v1.json
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: <app>-db-backup
  namespace: <namespace>
spec:
  cluster:
    name: <app>-db
  schedule: "@hourly"
  backupOwnerReference: self
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

## Step 5: Wire the dependencies in ks.yaml

The database is a second Flux Kustomization in the application's `ks.yaml`. The database Kustomization depends on the operator; the app Kustomization depends on the database. From `kubernetes/apps/atuin/atuin/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app>
  namespace: flux-system
spec:
  targetNamespace: <namespace>
  dependsOn:
    - name: <app>-db
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/<namespace>/<app>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app-db <app>-db
  namespace: flux-system
spec:
  targetNamespace: <namespace>
  dependsOn:
    - name: cloudnative-pg
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app-db
  path: ./kubernetes/apps/<namespace>/<app>/db
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

The `dependsOn` name must match the operator's Flux Kustomization name (`cloudnative-pg`). Since the database Kustomization lives inside the app's `ks.yaml`, the namespace index does not need a new entry.

## Step 6: Connect the application

Two options, both used in this repository:

1. **Secret with the connection string.** Store the connection URI in the app's own Secret (`*.sops.yaml`) and mount it with `envFrom`. Atuin does this in `kubernetes/apps/atuin/atuin/app/helmrelease.yaml`:

   ```yaml
   envFrom:
     - secretRef:
         name: <app>-secret
   ```

2. **Reference the database service directly.** CloudNative-PG publishes read-write and read-only services (`<cluster>-rw`, `<cluster>-ro`) inside the namespace, and each Pooler adds a service named after itself (for example `<app>-db-pooler-rw`). Point the app at `<service>.<namespace>.svc.cluster.local` on port `5432`.

CloudNative-PG also publishes connection details for each cluster in a generated Secret (by default named `<cluster>-app`); inspect the namespace's secrets to see the exact name and keys in your deployment.

If the app reads discrete variables (host, user, password), you can also reference the generated secret's keys with `env.valueFrom.secretKeyRef`.

## Verification

```bash
flux get kustomizations | grep <app>-db
kubectl -n <namespace> get cluster
kubectl -n <namespace> describe cluster <app>-db     # look for "Cluster in healthy state"
kubectl -n <namespace> get pods
kubectl -n <namespace> get pooler
kubectl -n <namespace> get scheduledbackup
```

Expect the Cluster to reach healthy state, the operator's pods plus the database instances to be running, and the pooler deployments to be ready.

## Notes

- Do not add `decryption` or `postBuild` to the `ks.yaml` documents; they are inherited from the `cluster-apps` parent (see [How Applications Deploy](explanation-flux-deployment-model.md)).
- The database manifests live in `kubernetes/apps`, so `make kubernetes-kubeconform` renders and validates them.
- Keep database secret files in `*.sops.yaml` form and run `make sops-encrypt` before committing.
- For broader backup and restore procedures, see [Backup and Restore](../backup-restore.md).

## Related documents

- [How to Add an Application](how-to-add-an-application.md)
- [How to Add Backups](how-to-add-backups.md)
- [Application Conventions Reference](reference-conventions.md)
- [How Applications Deploy: The Flux Deployment Model](explanation-flux-deployment-model.md)
