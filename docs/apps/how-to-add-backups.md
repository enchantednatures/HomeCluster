# How to Add Backups to an Application

This guide adds VolSync backups for an application's persistent volumes, using the `immich` backup component (`kubernetes/apps/immich/immich/backup/`) as the reference implementation.

## Prerequisites

- The application is deployed per [How to Add an Application](how-to-add-an-application.md) and uses at least one PersistentVolumeClaim.
- The `volsync` operator Kustomization is deployed (it is part of the operators layer).
- An S3-compatible endpoint plus credentials for the restic repository.
- The exact PVC names to protect. Find them with:

  ```bash
  kubectl -n <namespace> get pvc
  ```

  or from the persistence section of the app's HelmRelease values.

## What gets created

| File | Resource | Purpose |
|------|----------|---------|
| `backup/kustomization.yaml` | Kustomization | Lists the component's resources |
| `backup/<app>-backup-secret.sops.yaml` | Secret | Restic repository credentials |
| `backup/replicationsource.yaml` | `volsync.backube/v1alpha1` ReplicationSource | Scheduled backup of a PVC |
| `backup/replicationdestination.yaml` | `volsync.backube/v1alpha1` ReplicationDestination | Restore path (paused by default) |
| `backup/ks.yaml` | Flux Kustomization | Delivers the backup component |

This component has its own `ks.yaml` file, so it must be registered in the namespace index separately (Step 5).

## Step 1: Create the backup directory

`backup/kustomization.yaml`, modeled on `kubernetes/apps/immich/immich/backup/kustomization.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./<app>-backup-secret.sops.yaml
  - ./replicationsource.yaml
  - ./replicationdestination.yaml
```

## Step 2: Create the repository Secret

VolSync's restic mover reads the repository location and credentials from the Secret named in `spec.restic.repository`. The key names used by the reference app (`kubernetes/apps/immich/immich/backup/immich-backup-secret.sops.yaml`) are `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY`. Create `backup/<app>-backup-secret.sops.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/v1/secret.json
---
apiVersion: v1
kind: Secret
metadata:
  name: <app>-backup-secret
  namespace: <namespace>
type: Opaque
stringData:
  RESTIC_REPOSITORY: s3:https://<endpoint>/<bucket>/<path>
  RESTIC_PASSWORD: <restic-repository-password>
  AWS_ACCESS_KEY_ID: <access-key>
  AWS_SECRET_ACCESS_KEY: <secret-key>
```

Encrypt before committing:

```bash
make sops-encrypt
```

## Step 3: Create the ReplicationSource (the backup)

`backup/replicationsource.yaml`, modeled on `kubernetes/apps/immich/immich/backup/replicationsource.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/volsync.backube/replicationsource_v1alpha1.json
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: <app>-backup
  namespace: <namespace>
spec:
  sourcePVC: <pvc-name>
  trigger:
    schedule: "20 2 * * *"
  restic:
    repository: <app>-backup-secret
    copyMethod: Direct
    retain:
      daily: 7
      weekly: 4
      monthly: 12
    pruneIntervalDays: 7
    storageClassName: ceph-block
    cacheStorageClassName: ceph-block
    cacheCapacity: 10Gi
    moverPodLabels:
      app: volsync-<app>-backup
```

Notes:

- Create **one ReplicationSource per PVC**. Stagger schedules between apps (immich runs at 02:20) so movers do not contend.
- `copyMethod: Direct` runs the mover pod co-located with the volume; the reference app uses it because its storage driver has no VolumeSnapshot support. `Snapshot` is an alternative when snapshots are available.
- `retain` and `pruneIntervalDays` define the restic retention policy and prune cadence.
- `storageClassName` / `cacheStorageClassName` (here `ceph-block`) provide scratch space and an incremental-backup cache for the mover.
- `moverPodLabels` makes mover pods easy to find while a job runs.

## Step 4: Create the ReplicationDestination (the restore path)

`backup/replicationdestination.yaml`, modeled on `kubernetes/apps/immich/immich/backup/replicationdestination.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/volsync.backube/replicationdestination_v1alpha1.json
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-restore
  namespace: <namespace>
spec:
  paused: true
  trigger:
    manual: ""
  restic:
    repository: <app>-backup-secret
    copyMethod: Direct
    destinationPVC: <pvc-name>
    cacheStorageClassName: ceph-block
    cacheCapacity: 10Gi
```

The destination is **paused** by default: Flux reconciles the manifest, but nothing restores until you clear `paused` and fire the manual trigger for a restore drill.

> Restoring targets a real PVC. For drills, point `destinationPVC` at a temporary claim rather than the live volume, and never restore over a volume that a running application is using without stopping the workload first.

## Step 5: Create the Flux Kustomization and register it

`backup/ks.yaml`, from `kubernetes/apps/immich/immich/backup/ks.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app>-backup
  namespace: flux-system
spec:
  targetNamespace: <namespace>
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: <app>
    - name: volsync
      namespace: flux-system
  path: ./kubernetes/apps/<namespace>/<app>/backup
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

The backup waits for the application (so the PVC exists) and for the `volsync` operator. Register this file in the namespace index — `kubernetes/apps/<namespace>/kustomization.yaml`:

```yaml
resources:
  - ./namespace.yaml
  - ./<app>/ks.yaml
  - ./<app>/backup/ks.yaml
```

## Step 6: Validate and commit

```bash
make kubernetes-kubeconform
pre-commit run --all-files
git add kubernetes/apps/<namespace>/<app>/backup kubernetes/apps/<namespace>/kustomization.yaml
git commit -m "feat(<namespace>): add <app> backups"
git push
```

## Verification

```bash
flux get kustomizations | grep <app>-backup
kubectl -n <namespace> get replicationsource
kubectl -n <namespace> describe replicationsource <app>-backup   # look for the last synchronization time
kubectl -n <namespace> get pods -l app=volsync-<app>-backup      # mover pod during a run
```

The first backup runs at the next scheduled time. Confirm it by watching the mover pod complete and checking the snapshot count in `describe replicationsource`.

## Notes

- **Database data**: a `ReplicationSource` copies whatever is in the PVC. For PostgreSQL, prefer the database-native path (`ScheduledBackup` with the `barman-cloud` plugin, see [How to Add a PostgreSQL Database](how-to-add-a-database.md)) and use VolSync for file storage.
- The backup Kustomization uses `wait: false` in the reference app; the Backup CRs are applied without waiting for the mover.
- For wider backup and restore procedures (including Ceph snapshots), see [Backup and Restore](../backup-restore.md).

## Related documents

- [How to Add a PostgreSQL Database](how-to-add-a-database.md)
- [How to Add an Application](how-to-add-an-application.md)
- [Application Anatomy Reference](reference-app-anatomy.md)
- [Backup and Restore](../backup-restore.md)
