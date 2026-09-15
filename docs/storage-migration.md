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
