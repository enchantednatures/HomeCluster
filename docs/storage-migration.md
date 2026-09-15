# Storage Migration: openebs-hostpath → Ceph

## Tiering matrix

| Workload | Target StorageClass | Rationale |
|---|---|---|
| media xarr configs (bazarr/dispatcharr/lidarr/prowlarr/radarr/readarr/sonarr, plex, tautulli, tdarr, hydra, seerr, sabnzbd, recyclarr) | `ceph-block-economy` | bulk, read-mostly, compression-friendly |
| monitoring (loki/tempo chunks, thanos store) | `ceph-block-economy` | size-first, lz4 offset HDD I/O |
| CNPG DBs (immich-db, lakekeeper-db, postgres, xarr-db) | `ceph-block` | latency-sensitive, small; native backup/restore (kubectl cnpg backup → bootstrap recovery) |
| elastic | `ceph-block` | search I/O; nvme-tier SCs unused in early migration |
| redpanda | `ceph-block` | kafka-style block storage on replica-3 |
| kubevirt VM disks + volsync pairs | `ceph-block` | small, latency-sensitive |
| media bulk assets (plex library, tdarr cache) — later | `ceph-block-economy` (HDD, replica 2) | large sequential, compression |

Pools backing these tiers:
- `ceph-blockpool` — replica 3, host-domain failure, span class (any)
- `ceph-blockpool-ssd` / `ceph-blockpool-nvme` — replica 3 on `ssd` CRUSH class (the 4 VM NVDemo disks)
- `ceph-blockpool-economy` — replica 2, failureDomain `osd`, `hdd` class (melusine's 4 HDDs, ~10 TiB)

## CRUSH device classes (as provisioned)

- work-00..03 OSDs (QEMU-passed NVMe): `ssd`
- melusine OSDs (bare-metal HDD pass-through): `hdd`

If an OSD shows the wrong class:
`ceph osd crush rm-device-class osd.N; ceph osd crush set-device-class ssd osd.N`

## VolumeSnapshotClasses

- `ceph-block-snapshot` (Retain, default)
- `ceph-block-snapshot-delete` (Delete)

## One whatever migration procedure (VolSync rsync pattern)

Per-PVC, HostPath → Ceph offline copy:
1. Scale the workload to zero (`kubectl scale deploy --replicas=0` or cnpg hibernation)
2. `ReplicationSource` on the openebs PVC (rsync copyMethod Direct), one-shot trigger
3. `ReplicationDestination` with `destinationPVC: <same-name>`, `storageClassName: ceph-block-economy`
4. Scale back up; delete the old PV manually (Retain polarity opposite) when the workload is green
5. Commit the ns/app cutover in this repo; remove the volsync migration pair

Reference implementation (will live in the repo as `*/migration/replication*.yaml`) — the
influxdb backup dir (`kubernetes/infra/monitoring/influxdb/backup/`) is today's volsync style guide.

## Status 2026-09-15 (handoff)

### Done + verified live
- Rook-Ceph enabled & healthy: 8 OSDs, 3 mon, 2 mgr, 2 rgw, 13 pools, 11TiB avail, HEALTH_OK
  - work-00..03 (QEMU-passed NVMe) → deviceClass ssd
  - melusine (bare-metal HDD passthrough) → 4 OSDs, deviceClass hdd (~10TiB)
  - economy pool: replica2, failureDomain osd, hdd class; crush rule ceph-blockpool-economy exists
- melusine main.tf trimmed to disk0 only; talos config re-applied with disks-patch
- Dead per-disk SCs (openebs-bulk-hdd-3t/-4t/-4t-b, openebs-ssd-480) removed from repo — 0 PVs used them
- Pilot validated on ceph-block-economy: PVC Bound, 32MiB write + md5 read
- infra fix during setup: kyverno require-pod-resources excludes rook-ceph
- Runbook files: `docs/storage-migration.md`; VolSync reference pattern (`influxdb/backup/`)

### NOT yet migrated (cutover batches OPEN)
- 50 PVCs still on openebs-hostpath (68 on csi-nfs; those are out of scope):
  media **36** (blocked: `kubernetes/apps/media/**` is gone from main; flux runs
  those apps from stale artifact revisions — resolve media-tree source of truth first)
  monitoring 7 — loki/tempo/kube-prom-stack/...; influxdb sts already scaled to 0
  (good first candidate: no downtime for users), CNPG ~10 DB clusters (use
  cnpg-native backup → cluster recreate; scp volsync rsync for other PVCs)
  elastic 3 / redpanda 3 / vms 3

### Operational temp setbacks (verify before assuming permanent)
- replicas lowered during the collapse-cascade: loki-chunks-cache(1),
  loki/tempo-ingester(-1 ea), istiod(1) — rebalance after DB migration lands
- node labels added by hand: work-00..03 `node-role.kubernetes.io/worker=""`
  (RGW placement needs it; put it in the melusine machineconfig / tofu labels)
- `ceph config set global mon_data_avail_warn 15` (was flapping at work-02's /var
  free space, now 69%+)
- work-01 carries `rook.enable-hostworks=true` label used only for the operator
  placement pin — removable once operator placement relies on FCNS only

### Cleanup at the end of the whole project
- disable localpv-provisioner in openebs helmrelease; delete remaining
  `/var/openebs/local` kubelet mount patch; then fully erase disk0 once the last
  PV is off it — this namespace only

## Blocking incident 2026-09-15 (mass migration暂停)

- influxdb is the pilot but its openebs PV is pinned to unraid-worker: kubelet
  rejects/evicts new pods on that node under DiskPressure — ribbon same for
  ctrl-01 (thanos-store, kube-apiserver listed in eviction set). Two nodes are
  currently disk-pressure tainted.
- Lifting the mass-migration outage requires at the Proxmox boundary:
  - Check ephemeral partition size on ctrl-01 (sda5) and unraid-worker (vda6)
  - wipefs the txh; delete the huge ephemeral Volume data and reshape at VM
    level; this means changing the tofu block
- Once nodes have disk headroom, un-taint (`kubectl taint node
  kubernetes.io/disk-pressure` is self-correcting by kubelet), then resume:
  1) influxdb copy per migration-pair.yaml
  2) batch of monitoring
  3) media (locate source of truth first, currently stale artifacts)
  4) elastic/redpanda/vms
- Also confirmed live during migration-pair changes: csi-rbd nodeplugin needed
  explicit tolerations patch (patched live; must be committed in the rook
  helmrelease `csi.` values — patch `tolerations` per the reference examples
  already in csi-operator-rbac.yaml)
