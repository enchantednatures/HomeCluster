# Ceph HDD Tier Capacity Plan

## Why this exists

The cluster has 9.5 TiB of unused HDD capacity, but the fast classes are full:

| Class | OSDs | Raw | Used | Notes |
|---|---|---|---|---|
| `hdd` | osd.0-2 | 10 TiB | 726 GiB (5-8%) | all on **melusine** |
| `ssd` | osd.3, osd.8 | 1.35 TiB | 1.2 TiB (73-96%) | melusine + unraid-worker |
| `nvme` | osd.4-7 | 932 GiB | 878 GiB (93-97%) | work-00..03, one per host |

Bulk data currently sits in untiered pools that use the default CRUSH rule
(`take default` + `chooseleaf host`), so replicas land on whichever hosts are
chosen, not on whichever class has space:

- `ceph-blockpool` (default StorageClass `ceph-block`): 645 GiB stored / 1.7 TiB raw at size 3
- `ceph-objectstore.rgw.buckets.data` (Loki/Thanos/Tempo): 310 GiB stored / 401 GiB raw
- `ceph-filesystem-data0` + metadata: 19 GiB / 58 GiB raw

The HDD class cannot be used safely for bulk data yet because **all three HDD
OSDs are on one host**. A pool with `failureDomain: host` and `size: 2` cannot
place two replicas on one host, and `ceph-blockpool-economy` already works
around this with `failureDomain: osd`, size 2 — which survives a disk failure
but not a node failure.

## Options

### Option A — add HDDs to a second node (recommended)

Add one or more HDDs to `unraid-worker` (or another worker with drive bays),
let Rook provision them into the `hdd` class, then create a host-redundant
archive tier.

- Usable capacity: ~5 TiB at size 2 across two hosts
- Host-level redundancy: yes
- Data migration required: yes
- Blast radius: new OSDs only; existing pools are untouched

### Option B — single-host archive tier (interim)

Use the existing `ceph-blockpool-economy` (HDD, `failureDomain: osd`, size 2)
for archive-only data. This is acceptable for reconstructible data (crates,
metrics history, backup caches) but not for primary application data.

- Usable capacity: ~5 TiB
- Host-level redundancy: no
- Fast to enable: pool already exists
- Use only for data that can be rebuilt or is already backed up

### Option C — keep the default rule and rely on the balancer

Do nothing structural; let the `upmap` balancer move PGs to HDDs. This does not
create a tier, keeps primary data on HDDs with no isolation, and the balancer is
currently blocked by degraded PGs. Not recommended.

## Target design (Option A)

| Tier | Class | Workloads |
|---|---|---|
| Ultra-low latency | `nvme` | databases, Prometheus, Harbor DB |
| General block | `ssd` | most application PVCs |
| Bulk / archive | `hdd` | media library, registry blobs, Loki/Thanos/Tempo, VolSync caches |
| CephFS metadata | `ssd` | `ceph-filesystem-metadata` |
| CephFS data (hot) | `ssd` | `ceph-filesystem-data0` |
| CephFS data (bulk) | `hdd` | new `data1` pool, directory-pinned |

## Migration sequence

1. **Add hardware.** Attach one or two HDDs to a second node (Proxmox passthrough
   or Talos disk), verify the device is visible, and let Rook create the OSDs.
2. **Verify CRUSH.**
   ```bash
   ceph osd tree
   ceph osd crush class ls
   ceph osd df
   ```
   Confirm the new OSDs are `hdd` and on a different host from `melusine`.
3. **Create the archive block pool.**
   - `CephBlockPool` `ceph-blockpool-archive`
   - `deviceClass: hdd`, `failureDomain: host`, size 2, `min_size: 1`
   - compression `lz4`, `pg_autoscale_mode: on`
   - StorageClass `ceph-block-archive`
4. **Move bulk PVCs.** VolSync is paused; choose one of:
   - new PVC on `ceph-block-archive` + `rsync`/VolSync restore, switch the app
   - `rbd migration` with the app stopped (offline, simpler for single-writer DBs)

   Candidates from the current default-SC set: `immich-library-pvc` (100 GiB),
   `kellnr` (50 GiB), `data-thanos-compact-0` (50 GiB), both `influxdb` volumes
   (50 GiB each), `netbootxyz-assets` (50 GiB), the five Loki volumes
   (10 GiB each), and the idle VolSync caches (10 GiB each).
5. **Add the CephFS bulk data pool.**
   - `dataPools: [{name: data1, deviceClass: hdd, failureDomain: host, replicated: {size: 2, requireSafeReplicaSize: true}}]`
   - StorageClass `ceph-filesystem-archive` with `pool: ceph-filesystem-data1`
   - Pin bulk directories with `setfattr -n ceph.dir.layout.pool -v ceph-filesystem-data1 <dir>`
   - Do **not** move the metadata pool to HDD.
6. **Tier the object store.** Create an HDD-backed `CephObjectStore` (or a
   dedicated HDD data pool) and migrate the large buckets with `mc mirror` or
   RGW multisite sync. OBCs cannot change placement in place.
7. **Fix quotas.** `ceph-blockpool-ssd` has a 500 GiB quota against 653 GiB of
   provisioned PVCs and ~95% physical use. Either lower the quota to the real
   usable capacity and migrate the excess, or add SSD capacity. Add an alert
   when `ceph df` pool usage exceeds 90%.
8. **Resume VolSync** only after the snapshot-trash issue is resolved (see
   below), then re-enable the `upmap` balancer once all PGs are clean.

## Capacity math

- HDD raw: 10 TiB; at size 2 with host redundancy: ~5 TiB usable
- Current HDD usage: 726 GiB; free for the archive tier: ~4.3 TiB
- Bulk candidates on the default pool: ~750 GiB provisioned
- RGW bulk buckets: ~310 GiB stored (~400 GiB raw)

Moving the bulk set to HDD would remove roughly 1 TiB of raw pressure from the
NVMe/SSD classes, which is enough to bring the five backfillfull OSDs below the
90% threshold.

## Risks and guardrails

- **Single-host HDD is not HA.** Do not put primary data on Option B.
- **Backfill load.** The cluster is still above `backfillfull`; run migrations
  after `ceph health` is clean or during a maintenance window.
- **Snapshot trash.** 4,495 trashed snapshots and 93 trashed volume images are
  stuck in an unpurgeable Ceph snapshot-trash state. `rbd snap purge` ignores
  them, `rbd snap rm --snap-id` reports "protected", and `rbd trash rm` reports
  "image has snapshots". Fix this at the Ceph level (upgrade or offline
  `ceph-objectstore-tool`) before relying on VolSync again.
- **VolSync pause.** All seven `ReplicationSource` objects are paused in Git
  (`fix(volsync): pause backups while Ceph recovers`). Re-enable them only
  after the trash leak is addressed.

## Validation

```bash
ceph health
ceph osd df
ceph fs status
ceph df detail
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage
```

## 2026-11-21: thanos-compact moved to economy

`data-thanos-compact-0` held 46.9 GiB of actual data on `ceph-block`. The
StatefulSet `volumeClaimTemplate` now uses `ceph-block-economy` (commit
`acf050a6`), and the scratch volume was recreated.

The old volume had 12 `csi-snap-*` children: 4 current daily snapshots plus 8
older orphans. The live `VolumeSnapshot`s were deleted, the orphan children
were removed, and the parent image was purged. Thanos Compact re-synced from
the object store and resumed compaction on economy.

Result:

- `ceph-blockpool`: 660 GiB / 100% -> 646 GiB / ~93%, max avail 44 GiB.
- Cluster: `HEALTH_ERR` -> `HEALTH_WARN`.
- `ceph-blockpool-economy`: ~59 MiB used of 4.5 TiB available.

`thanos-store` remains on `ceph-block` (5Gi claim, ~2Gi used); it is not worth
the migration risk yet. VolSync is paused; consider pausing the daily
`volume-snapshot-automation` CronJob too until the cluster is fully clean.
