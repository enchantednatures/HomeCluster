# Backup & Restore Runbook (VolSync → MinIO)

Status: live, pilot-verified 2026-09-09. Every command in this document was executed during the pilot tasks and is cited to an evidence file under `.sisyphus/evidence/`. Nothing here is untested.

## 1. Overview

VolSync v0.16.0 restic movers back up 7 PVCs to an external MinIO server at `192.168.1.241:9768`, reached in-cluster via the FQDN `minio-service.networking.svc.cluster.local:9768` (selectorless ClusterIP Service + manual Endpoints). The connection is plain HTTP. That is an accepted risk on this LAN: restic credentials transit unencrypted between mover pods and MinIO.

Each PVC gets its own restic repository under the `volsync-backups` bucket, path convention `<namespace>-<pvc-name>`. Example (verified in `task-3-restic-repo-format.txt`):

```
s3:http://minio-service.networking.svc.cluster.local:9768/volsync-backups/vms-arch-linux-root
```

Retention on every ReplicationSource: 7 daily / 4 weekly / 12 monthly, `pruneIntervalDays: 7`. `copyMethod: Direct` everywhere, which means the mover reads the live volume without a snapshot clone. Backups are therefore crash-consistent, not application-consistent. This is why databases are excluded from VolSync entirely: CNPG, Kafka, Elastic, and ArangoDB use their native backup tooling instead. kellnr-db has WAL archiving only, which is a known gap (see risks).

### Backup roster (matches Git exactly)

| App | NS | PVC | Schedule (UTC) | Cache | Mover uid |
|---|---|---|---|---|---|
| arch-linux VM | vms | arch-linux-root | `0 2 * * *` | 10Gi openebs-hostpath | 107 (qemu) |
| immich | immich | immich-library-pvc | `20 2 * * *` | 10Gi csi-nfs | default |
| gitea | gitea | gitea-data | `40 2 * * *` | 10Gi csi-nfs | 1000 |
| kellnr | kellnr | kellnr | `0 3 * * *` | 10Gi csi-nfs | default |
| influxdb | monitoring | influxdb-influxdb2 | `20 3 * * *` | 10Gi openebs-hostpath | 1000 |
| home-assistant | home-system | home-assistant-config | `40 3 * * *` | 5Gi csi-nfs | default |
| node-red | home-system | node-red | `0 4 * * *` | 5Gi csi-nfs | 1000/150/140 |

ReplicationSource names: `arch-linux-backup`, `immich-backup`, `gitea-backup`, `kellnr-backup`, `influxdb-backup`, `home-assistant-backup`, `node-red-backup`. Each app also has a paused ReplicationDestination named `<app>-restore` for rebuilds.

kellnr caveat: the `kellnr` PVC holds almost nothing (the pilot backup processed 0 files). Crates live in MinIO `kellnr-*` buckets and the package index lives in the kellnr-db Postgres database. Real kellnr protection is MinIO bucket replication plus a CNPG ScheduledBackup for kellnr-db; both are documented follow-ups.

Evidence: `task-3-restic-repo-format.txt`, `task-8-influxdb-backup.log`, `task-7-kellnr-backup.log`, notepad `decisions.md`.

## 2. Day-2 operations

Evidence: `task-8-influxdb-backup.log`, `task-8-scope-check.txt`, `task-3-backup.log`, `task-3-restore.log`, `task-3-mover-labels.txt`, `task-11-blocked-report.txt`.

### Status checks

```sh
# One namespace (proven form, task-8-scope-check.txt)
kubectl -n monitoring get replicationsource

# Full detail as JSON (proven, task-8-influxdb-backup.log)
kubectl -n monitoring get replicationsource influxdb-backup -o json
```

Useful fields in the JSON: `.status.lastSyncTime`, `.status.lastSyncDuration`, `.status.nextSyncTime`, `.status.latestMoverStatus.result`, and `.status.latestMoverStatus.logs` (contains the restic snapshot ID, e.g. `snapshot b1b10ce8 saved`).

VolSync deletes the mover Job shortly after success, so poll the RS/RD status rather than pod phase. Pod-phase pollers return empty after cleanup.

Check the backup Kustomizations reconciled:

```sh
flux get kustomizations -A | grep <app>
```

Column gotcha: in `flux get kustomizations` output, SUSPENDED comes before READY. Read the columns carefully; agents misread this twice during the pilot.

### Manual trigger

Patch a unique `trigger.manual` value (proven, task-8-influxdb-backup.log):

```sh
kubectl -n monitoring patch replicationsource influxdb-backup \
  --type merge -p '{"spec":{"trigger":{"manual":"rollout-1788968037"}}}'
```

Two gotchas, both proven:

1. Flux reverts the patch on reconcile (KS interval 30m, faster when sibling pushes re-trigger the root KS). The trigger value never needs to be committed; a reverted trigger does not mean the sync failed. Completion is proven by `lastSyncTime` + `latestMoverStatus.result: Successful` + snapshot ID in the mover logs.
2. Use a unique value each time (timestamp suffix works: `rollout-<unix-ts>`). Reusing a value does nothing.

### Reading mover logs

After a sync, read `.status.latestMoverStatus.logs`. A successful run looks like (task-8-influxdb-backup.log):

```
=== Initialize Dir ===
created restic repository b54f61ec73 at s3:http://minio-service.networking.svc.cluster.local:9768/volsync-backups/monitoring-influxdb-data
no parent snapshot found, will read all files
Added to the repository: 185.723 KiB (6.227 KiB stored)
processed 2 files, 184.000 KiB in 0:00
snapshot b1b10ce8 saved
Restic completed in 4s
```

`no parent snapshot found` on the first run is normal. Later runs should say `using parent snapshot <id>`.

### Failed-Job triage

Check the mover Job labels if you need to inspect it (proven, task-3-mover-labels.txt):

```sh
kubectl -n vms get job volsync-src-arch-linux-backup --show-labels
```

Failure modes seen in the pilot:

| Symptom | Cause | Fix |
|---|---|---|
| `open disk.img: permission denied` in mover logs | mover uid cannot read PVC files | `restic.moverSecurityContext` matching the app's uid/gid/fsGroup (already set in Git for arch 107, gitea 1000, influxdb 1000, node-red 1000/150/140) |
| restic `parsing repository location failed: invalid backend` | placeholder RESTIC_REPOSITORY in the secret | put real values in the secret before triggering (task-6-gitea-roundtrip.log) |
| Kyverno `require-pod-resources` blocks the mover Job | namespace not in the Kyverno exclusion list | `restic.moverResources` with cpu/memory requests and a memory limit (already set in Git for gitea, home-assistant, node-red) |
| Mover pod Pending ~15 min, `Too many pods` | unraid-worker at max-pods 110/110; movers are node-pinned to the PV node | wait for a slot to free; FailedScheduling does not consume Job backoffLimit, the Job schedules when capacity appears (task-8-influxdb-backup.log) |

### Stale restic locks after node disruption

If a node is disrupted mid-sync (TaintManagerEviction kills the mover pod), the mover Job wedges: it never recreates the pod because Flux reverted the `paused` patch and the Job runs with parallelism=0. Recovery procedure, proven in task-3-restore.log:

1. Delete the wedged Job (action proven in task-3-restore.log timeline: "deleted wedged job"; Job name pattern `volsync-dst-<rd-name>` per task-8-influxdb-backup.log):

```sh
kubectl -n vms delete job volsync-dst-arch-linux-restore
```
2. Re-patch `paused: false` AND a new unique `trigger.manual` together.
3. The pod reschedules on the PV node and the sync completes.

## 3. Cluster-rebuild restore procedure

This is the procedure proven end-to-end in task-3-restore.log (arch-linux, openebs-hostpath, 40GiB) and task-6-gitea-roundtrip.log (gitea, csi-nfs). One app is walked as the example; repeat per app.

Do NOT delete existing PVCs before restoring. The ReplicationDestination restores INTO the existing empty PVC via `destinationPVC`.

### Step 0: age key and SOPS secrets first

SOPS decryption is the root dependency for everything: Flux cannot decrypt any secret, including the restic `RESTIC_PASSWORD`, without the age key.

WARNING: if the age key is lost, `RESTIC_PASSWORD` is unrecoverable, and without `RESTIC_PASSWORD` the restic repositories are unrecoverable. The backups exist but cannot be opened. The age key is backed up outside this cluster by the user; verify it exists before any rebuild.

### Step 1: Flux bootstraps

Bootstrap Flux against this repo. Apps deploy with empty PVCs and the backup Kustomizations reconcile, creating the ReplicationSources and the paused ReplicationDestinations.

### Step 2: suspend each ReplicationSource

Flip `spec.paused: true` via Git commit on each app's `replicationsource.yaml`. This prevents the scheduled cron from snapshotting the empty volumes.

### Step 3: trigger each ReplicationDestination

Each RD is committed with `paused: true`. To restore, flip `paused: false` and set `trigger.manual` to a unique value, in the same Git commit, then let Flux apply it. Git is the preferred path.

For urgent rebuilds a temporary kubectl patch is acceptable (proven, task-3-restore.log timeline: "patched paused:false + trigger manual"):

```sh
kubectl -n vms patch replicationdestination arch-linux-restore \
  --type merge -p '{"spec":{"paused":false,"trigger":{"manual":"restore-pilot-1788966227"}}}'
```

CRITICAL GOTCHA (task-3-restore.log): patch `paused` AND `trigger` TOGETHER. If you patch only the trigger, Flux reverting `paused` mid-flight deadlocks the mover Job at parallelism=0 and you get a wedged Job (see section 2 recovery). Also finish the sync within the Flux reconcile interval, or re-patch.

### Step 4: monitor the restore Job

Poll the RD status (VolSync deletes the Job on success). The RD status JSON captured in task-3-restore.log was read the same way as the RS example in section 2:

```sh
kubectl -n vms get replicationdestination arch-linux-restore -o json
```

Success looks like (task-3-restore.log):

```
"lastManualSync": "restore-pilot-1788966227",
"lastSyncDuration": "48m13.320891091s",
"latestMoverStatus": {
    "logs": "restoring snapshot b449cbd7 of [/data] at ... \nRestic completed in 466s",
    "result": "Successful"
}
```

The RD restic mover restores the LATEST snapshot by default.

### Step 5: verify data with a busybox Job

Mount the destination PVC in a verification pod and confirm it is non-empty. Exact commands and outputs from task-3-restore.log (openebs-hostpath path):

```
ls -A /data
  disk.img
du -sh /data
  40.0G /data
ls -l /data
  -rw-rw---- 1 107 107 42949672960 Sep  9 14:40 disk.img
```

And from task-6-gitea-roundtrip.log (csi-nfs path):

```
ls -A /data
  actions_artifacts
  actions_log
  attachments
  avatars
  git
  gitea
  home
  jwt
  packages
  repo-archive
  repo-avatars
  ssh
du -sh /data
  36.0K /data
```

Note for openebs-hostpath PVCs: the mover pod is node-pinned to the PV node, and a QA pod can double-mount the RWO PVC only from the same node (proven in task-3-restore.log, busybox QA pod on melusine).

### Step 6: validate, then flip back

Validate file counts and sizes against expectations (Step 5 output). Then, via Git commit:

- re-pause each ReplicationDestination (`paused: true`)
- un-pause each ReplicationSource (`paused: false`)

Backups resume on schedule.

## 4. Secrets

Each app has one secret at `<app-dir>/backup/*-backup-secret.sops.yaml` (SOPS/Age encrypted, only `data`/`stringData` fields encrypted). It holds exactly 4 keys (verified in task-5-secret-hygiene.txt and task-3-restic-repo-format.txt):

| Key | Value |
|---|---|
| AWS_ACCESS_KEY_ID | MinIO access key |
| AWS_SECRET_ACCESS_KEY | MinIO secret key |
| RESTIC_REPOSITORY | `s3:http://minio-service.networking.svc.cluster.local:9768/volsync-backups/<ns>-<pvc>` |
| RESTIC_PASSWORD | per-repo random password (`openssl rand -base64 32`), generated once |

Verify a live secret value before triggering (proven pattern, task-6 learnings):

```sh
kubectl -n gitea get secret gitea-backup-secret -o jsonpath='{.data.RESTIC_REPOSITORY}' | base64 -d
```

SOPS edit flow (proven, task-6-gitea-roundtrip.log): `sops -e /tmp/plain.yaml > target.sops.yaml` FAILS because creation rules match the input path, and the redirect truncates the target first. Correct flow: decrypt the target, edit, copy over the target, then `sops --encrypt --in-place target`.

Rotation warning: a new RESTIC_PASSWORD means a new restic repository. The password IS the repo key; restic cannot open the old repo with a new password. A fresh password is only safe when the repo path has never been initialized (task-3-restic-repo-format.txt).

## 5. Known risks

- Plain-HTTP MinIO: restic credentials and data transit unencrypted over the LAN. Accepted risk (task-3-restic-repo-format.txt).
- Crash-consistency: `copyMethod: Direct` reads live volumes with no snapshot/quiesce. Databases (CNPG, Kafka, Elastic, ArangoDB) are excluded from VolSync for this reason and use native backup tooling.
- kellnr-db gap: WAL archiving only, no ScheduledBackup yet. kellnr PVC backup protects ~nothing (crates are in MinIO buckets, index in Postgres). Follow-ups: MinIO bucket replication for `kellnr-*` buckets + CNPG ScheduledBackup for kellnr-db.
- Age key is the root of trust: losing it loses every backup (Step 0 warning).
- Node capacity: unraid-worker runs at max-pods 110/110. Movers pinned to that node may pend ~15 min under load (task-8-influxdb-backup.log).

## 6. Recovery drill checklist

Quarterly: walk section 3 for ONE app end to end.

- [ ] Age key present and SOPS decrypts `kubernetes/flux/vars/cluster-secrets.sops.yaml`
- [ ] Pick one app; confirm its RS is syncing (`kubectl -n <ns> get replicationsource -o json`, `latestMoverStatus.result: Successful`)
- [ ] Suspend the RS (`paused: true` via Git)
- [ ] Un-pause + trigger the RD (paused + trigger together)
- [ ] Restore Job succeeds (`latestMoverStatus.result: Successful`, snapshot ID in logs)
- [ ] busybox verify: `ls -A /data` non-empty, `du -sh /data` plausible
- [ ] Re-pause RD, un-pause RS via Git
- [ ] Confirm next scheduled sync fires (`nextSyncTime` honored)
