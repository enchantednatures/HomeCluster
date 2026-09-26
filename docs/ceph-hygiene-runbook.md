# Ceph Health Hygiene Runbook

## 1. Scope and accepted end state

This runbook is the durable operational record for the Ceph health hygiene pass on the HomeCluster cluster. It explains why the cluster runs at `HEALTH_WARN` by design, how to reproduce and verify the accepted end state, and how to roll the device-class changes back.

Cluster baseline: Rook `v1.20.7`, Ceph `20.2.4` (Tentacle), Talos `v1.13.9` with kernel `6.18.44-talos` on all seven nodes. Last verified: 2026-09-26.

The accepted end state is a single `HEALTH_WARN` with exactly these codes:

| Code | State | Reason |
|---|---|---|
| `AUTH_INSECURE_CLIENT_KEY_TYPE` | present, unmuted, count 4 | Kernel-gated, see section 2 |
| `AUTH_INSECURE_KEYS_ALLOWED` | present, muted | Mute is display-only; Rook-level mute in `ceph-cluster.yaml` |
| `AUTH_INSECURE_KEYS_CREATABLE` | present, muted | Mute is display-only; Rook-level mute in `ceph-cluster.yaml` |
| `BLUESTORE_SLOW_OP_ALERT` | present, unmuted (osd.8) | Accepted residual, T7 returned NO-GO, see section 7 |

`RECENT_MGR_MODULE_CRASH` must be absent. It was the main target of this pass and is cleared by crash archiving, see section 3.

The classic transient `SLOW_OPS` check is tolerated. It names melusine HDD OSDs (`osd.1`, `osd.2`) during host-latency flaps. It is not a stable code in `ceph health --format=json` on this cluster, but the verification Job treats it as accepted so a transient flap cannot fail an otherwise-correct end state.

The plan's original "exactly 3 warnings" target was amended to include the accepted `BLUESTORE_SLOW_OP_ALERT` residual, because Task 7 returned NO-GO for the slow-op OSD (section 7).

## 2. Kernel-gated AUTH_INSECURE warnings

### What the warning says

`AUTH_INSECURE_CLIENT_KEY_TYPE` reports four auth client entities that still hold a legacy `aes` cephx key:

```
entity client.csi-cephfs-node.2 using insecure key type: aes
entity client.csi-cephfs-provisioner.2 using insecure key type: aes
entity client.csi-rbd-node.2 using insecure key type: aes
entity client.csi-rbd-provisioner.2 using insecure key type: aes
```

These are the CSI identities (`.2` = key generation 2) that Rook creates for the CephFS and RBD drivers. The count of 4 is stable and expected.

### Legacy `aes` versus secure `aes256k`

Ceph cephx supports two key types. The legacy type `aes` uses a 128-bit key. The secure type `aes256k` uses a 256-bit key. `AUTH_INSECURE_CLIENT_KEY_TYPE` exists because of CVE-2025-30156, where the weaker legacy `aes` key type is considered insecure for cephx authentication. Moving CSI entities from `aes` to `aes256k` is the fix the warning is asking for.

`msgr2` wire encryption is a separate gate and is already satisfied on this cluster (`network.connections.encryption` is configured in `ceph-cluster.yaml`). Satisfying `msgr2` does not remove `AUTH_INSECURE_CLIENT_KEY_TYPE`; that warning is purely about the on-disk cephx key type.

### Why the key type stays `aes` today

Mounting a CephFS or RBD volume whose cephx key is `aes256k` requires the **host kernel to be 7.0 or newer**. All Talos nodes currently run kernel `6.18.44-talos`, which is below 7.0. If CSI rotated to `aes256k` today, the kernel would reject the key and volume mounts would fail. This is why `spec.security.cephx.csi.keyType` stays `aes` with `keyGeneration: 2` in `kubernetes/operators/rook-ceph/cluster/app/ceph-cluster.yaml`:

```yaml
security:
  cephx:
    csi:
      keyType: aes
      keyRotationPolicy: KeyGeneration
      keyGeneration: 2
      keepPriorKeyCountMax: 1
```

The `aes256k` migration is therefore blocked on the Talos kernel, not on Ceph or Rook. This warning cannot be cleared by any manifest change while the kernel gate stands.

### What unlocks it

1. Upgrade Talos so every node runs **kernel 7.0 or newer**. Confirm with `uname -r` on each node before proceeding.
2. Set `spec.security.cephx.csi.keyType` to `aes256k` and bump `keyGeneration` (for example to `3`) to trigger rotation.
3. Rotate the CSI keys in a controlled order. Drain CSI-using workloads node by node, let the new generation land, and confirm mounts succeed before moving to the next node. Keeping `keepPriorKeyCountMax: 1` leaves the prior key valid during the rotation window.
4. Only after every CSI entity is confirmed on `aes256k` and no `aes` keys remain, consider restricting `auth_allowed_ciphers` on the monitors to disallow the legacy `aes` type.

### Why NOT to restrict `auth_allowed_ciphers` before the kernel upgrade

Restricting `auth_allowed_ciphers` (or tightening `AUTH_INSECURE_KEYS_ALLOWED` / `AUTH_INSECURE_KEYS_CREATABLE`) to disallow `aes` while the four `client.csi-*` entities still hold `aes` keys would break their authentication immediately. Every CephFS and RBD CSI mount in the cluster would fail at once, a cluster-wide storage lockout that is far worse than the warning it tries to silence. This order is load-bearing: kernel upgrade first, then `aes256k` rotation, and only then any cipher restriction. Do not reverse it.

## 3. Crash hygiene

### archive-all versus prune

`ceph crash archive-all` moves every unarchived crash into the archive. Archiving is what clears the `RECENT_MGR_MODULE_CRASH` health warning, because the warning counts unarchived crash records.

`ceph crash prune 14` is retention only. It deletes archived crash records older than 14 days. It does NOT clear `RECENT_MGR_MODULE_CRASH` on its own. Treating `prune` as the fix is the single most common mistake here.

### What runs

`kubernetes/operators/rook-ceph/cluster/app/ceph-crash-hygiene.yaml` defines both:

- One-shot `Job/rook-ceph-crash-archive-v1`: archives the backlog and then prunes. Already completed and verified; `RECENT_MGR_MODULE_CRASH` is gone and unarchived crash count is 0.
- Recurring `CronJob/rook-ceph-crash-hygiene`: schedule `17 3 * * *`, time zone UTC, `concurrencyPolicy: Forbid`. It runs `ceph crash archive-all` then `ceph crash prune 14` daily so the backlog cannot rebuild.

### EIO fallback (tracker 79357)

At very large crash backlogs, `ceph crash archive-all` can fail with `Error EIO` (tracker 79357). The Job handles this: when the command exits non-zero and its output contains `EIO`, the script runs `ceph mgr fail`, polls up to 30 seconds for a responsive mgr, and retries `ceph crash archive-all` exactly once. A non-EIO failure exits with the original status. If `EIO` persists after the retry, the Job fails and this is a real incident rather than a transient mgr issue.

### Maintenance notes

- Job names are versioned (`*-v1`) because Flux cannot mutate a completed or flux-managed Job's immutable spec in place. To re-run, add a new versioned Job (for example `rook-ceph-crash-archive-v2`) rather than editing the existing one.
- `ttlSecondsAfterFinished: 86400` keeps completed Jobs for one day for log inspection, then garbage-collects them.
- Rerunning archive and prune is idempotent. Both are no-ops on an empty crash list.

## 4. The `rook` mgr module is disabled

### Why

The Ceph `prometheus` mgr module calls `node_proxy_fullreport()` on the `rook` mgr module. With Rook v1.20.7 that call raises `NotImplementedError` roughly every 15 seconds, producing a crash storm (Rook issue #18124, tracker 79106). The pass disabled the `rook` mgr module in `ceph-cluster.yaml` (`mgr.modules`, `name: rook`, `enabled: false`) to remove an unconditional crash source at the source.

This is a removal of the crash source, not a mute. The crashes previously drove `RECENT_MGR_MODULE_CRASH` to 4018 records. With the module disabled, no new crashes are generated, and section 3 archives the backlog.

### Trade-off

While the `rook` mgr module is disabled, `ceph orch` CLI commands and the Ceph dashboard orchestrator integration are unavailable. Day-to-day RBD, CephFS, and RGW data services are unaffected.

### Exit criteria to re-enable

Re-enable the `rook` mgr module only when Ceph ships the ceph/ceph#70967 backport inside a released 20.2.x. Confirm the running image (`quay.io/ceph/ceph:v20.2.4` today) includes the fix, then flip `enabled: false` back to `true` and reconcile. Until then, leave it disabled.

## 5. Device-class truth and pool re-home

### What was wrong

OSD hardware on `work-00` through `work-03` (`/dev/sdb`, which maps to `osd.4` to `osd.7`) is rotational HDD. `ceph osd metadata` showed `rotational=1` and `bluestore_bdev_type=hdd`, but the CephCluster CR declared `deviceClass: ssd` for those nodes. The class label was untruthful hardware metadata. `osd.8` (`unraid-worker`, `/dev/sda`) is genuinely `rotational=0` and correctly stays `ssd`. `osd.0` to `osd.3` on `melusine` are auto-detected and untouched.

### The declarative fix and the runtime fix

The CephCluster CR nodes for `work-00` to `work-03` were corrected to `deviceClass: hdd`. That edit alone is not enough:

**Rook v1.20.7 does NOT re-home an existing CephBlockPool's CRUSH rule when `spec.deviceClass` changes.** After the CR edit reconciled, the live `CephBlockPool` objects showed `deviceClass: hdd` and Rook logged a successful pool reconcile, yet `ceph osd crush rule dump` still showed `take default~ssd`. The actual CRUSH rule move was performed at runtime by `Job/rook-ceph-reclass-v1` (`ceph-reclass-job.yaml`), which reclassified `osd.4` to `osd.7` one at a time and re-homed both pools.

### Why the pools had to move

`ceph-blockpool-ssd` and `ceph-blockpool-nvme` are `replicated.size: 3` with `failureDomain: host`, pinned to the `ssd` class. After reclassifying `osd.4` to `osd.7` to `hdd`, the `default~ssd` bucket held only `osd.3` (`melusine`) and `osd.8` (`unraid-worker`), two hosts. A size-3 host-failure-domain pool cannot stay healthy on two hosts, so both pools would have gone permanently degraded. The re-home to a rule that takes `default~hdd` was mandatory and had to happen in the same window as the reclass.

The reclass Job orders the work as: reclass `osd.4`, `osd.5`, `osd.6`, then re-home both pools to `default~hdd`, then reclass `osd.7`. This keeps `default~ssd` at three hosts (`osd.3`, `osd.7`, `osd.8`) until the pools no longer need it.

### End state

`osd.4` to `osd.7` are class `hdd`; `osd.3` and `osd.8` remain class `ssd`. Both pools resolve to canonical rules (`ceph-blockpool-ssd`, `ceph-blockpool-nvme`) whose `steps` take `default~hdd`. No degraded, undersized, or stale placement groups.

## 6. Flux substitution gotcha (important follow-up)

The `rook-ceph-cluster` Flux Kustomization (`kubernetes/operators/rook-ceph/cluster/ks.yaml`) disables Flux post-build substitution:

```yaml
labels:
  substitution.flux.home.arpa/disabled: "true"
```

The reason is that the toolbox and Job scripts contain shell variables such as `${ROOK_CEPH_USERNAME}`, `${CEPH_CONFIG}`, and `${KEYRING_FILE}`. With substitution enabled, Flux v2.9.5 silently blanks unknown `${VAR}` expressions (non-strict mode), which would corrupt those scripts at render time.

The consequence is that `${SECRET_DOMAIN}` is also left unsubstituted in this Kustomization. That is why `spec.hosting.dnsNames` was removed from `ceph-object-store.yaml`; leaving it would have produced a literal `${SECRET_DOMAIN}` hostname.

Future fix: escape the shell variables as `$${VAR}` so Flux leaves them alone, then re-enable substitution on the Kustomization, and only then restore `dnsNames` using `${SECRET_DOMAIN}`.

## 7. Slow-op OSD (`BLUESTORE_SLOW_OP_ALERT`)

Task 7 investigated this warning in depth. Full detail is in `.sisyphus/evidence/task-7-slow-osd-diagnostics.md` and the decision is in `.sisyphus/evidence/task-7-branch-decision.txt`.

### Findings

- The alert names `osd.8` on `unraid-worker`, stable across 6 of 6 samples over roughly five minutes. The apparent "flap" is between two different checks: `BLUESTORE_SLOW_OP_ALERT` (always `osd.8`) and the classic transient `SLOW_OPS` (sometimes `osd.1` or `osd.2`).
- `osd.8` is already SSD-backed. `ceph osd metadata` shows `rotational=0`, `bluestore_bdev_type=ssd`, `bluefs_single_shared_device=1`, `bluefs_dedicated_db=0`. Its DB and WAL are collocated on the already-SSD data device.
- The decisive counters (`slow_committed_kv_count=1208`, `slow_aio_wait_count=50`) were static over a live 47 second window while transaction count grew by more than 800, so the condition is residual and sticky rather than worsening.
- The elevated field is `state_aio_wait_lat` (about 11.7 ms, roughly ten times peers), which points at block-device I/O wait on the QEMU virtual disk. The RocksDB sync path is actually the fastest of the sampled OSDs (`submit_sync_latency` about 3.99 ms), so this is not a DB or WAL placement problem.
- All SMART status checks pass, there is no `DEVICE_HEALTH` warning, BlueFS is 94.3 percent free, and allocator fragmentation is about 0.05 percent.

### Decision

T7b (metadataDevice reprovision) is **NO-GO** and void. The slow OSD is already SSD-backed, so a metadata device would provide no benefit, and `osd.8` is a no-touch guardrail. The only HDDs where a metadata device could theoretically help (`osd.0` to `osd.2`) are also no-touch (`melusine`), and `osd.4` to `osd.7` are not slow.

### Fallback

Monitor, do not mutate. Re-sample `ceph tell osd.8 perf dump bluestore` for the `slow_*` counters and `state_aio_wait_lat`. Re-open the decision only if `slow_committed_kv_count` or `slow_aio_wait_count` start increasing and the alert outlives its sticky window. Investigate the Proxmox and QEMU virtual-disk I/O path on `unraid-worker` (disk cache mode, SATA/AHCI controller, host contention); the bottleneck is device-level and out of scope for a Ceph metadata change. Do not touch `melusine` or `osd.8` while the guardrail stands.

## 8. Rollback playbook

### CRUSH checkpoint

Before any mutation, `Job/rook-ceph-reclass-v1` exported the CRUSH map and logged it as base64 between the markers `CRUSHMAP_CHECKPOINT_BASE64_BEGIN` and `CRUSHMAP_CHECKPOINT_BASE64_END`. Retrieve it from the Job logs:

```bash
kubectl -n rook-ceph logs job/rook-ceph-reclass-v1 \
  | sed -n '/CRUSHMAP_CHECKPOINT_BASE64_BEGIN/,/CRUSHMAP_CHECKPOINT_BASE64_END/p' \
  | sed '1d;$d' | base64 -d > crush.checkpoint.bin
```

The checkpoint was taken while `previousHealth: HEALTH_ERR` was observed, so treat it as a structural safety net rather than a known-good health snapshot. The reclass Job also gated every step on the absence of `PG_DEGRADED`, `PG_AVAILABILITY`, and `PG_DAMAGED`, so it never proceeded through real degradation.

### Reverting device classes

To return `osd.4` to `osd.7` to the `ssd` class:

```bash
for osd in 4 5 6 7; do
  ceph osd crush rm-device-class "${osd}"
  ceph osd crush set-device-class ssd "${osd}"
done
```

Revert one OSD at a time and check for degraded placement groups between steps, the same way the forward Job did.

### Reverting pool rules

The canonical `ceph-blockpool-ssd` rule now takes `default~hdd`. To point the pools back to a `default~ssd` rule:

```bash
ceph osd crush rule create-replicated ceph-blockpool-ssd-ssd default host ssd
ceph osd pool set ceph-blockpool-ssd crush_rule ceph-blockpool-ssd-ssd
ceph osd crush rule create-replicated ceph-blockpool-nvme-ssd default host ssd
ceph osd pool set ceph-blockpool-nvme crush_rule ceph-blockpool-nvme-ssd
```

Revert the pools only once `default~ssd` again holds at least three hosts, otherwise the size-3 host-failure-domain pools will degrade.

### setcrushmap caveats

Applying the checkpoint with `ceph osd setcrushmap -i crush.checkpoint.bin` restores bucket topology and device classes in one shot, but it is a blunt instrument:

- Pools store their `crush_rule` by **numeric id**, not by name. If the restored map renumbers rules, a pool can point at the wrong rule or a nonexistent id. Always follow a `setcrushmap` restore with `ceph osd pool ls detail` and `ceph osd crush rule dump` to confirm every pool's rule and its `item_name` are what you expect.
- Prefer the targeted class and rule commands above unless the map is badly corrupted.

### OSD class re-assert on restart

`osd_class_update_on_start` defaults to `true` in Ceph. That means an OSD restart may re-assert the device class auto-detected from the hardware, overwriting a manual `set-device-class`. After any OSD restart, re-check `ceph osd crush tree --show-shadow` and `ceph osd tree`. The CephCluster CR now declares `hdd` for `work-00` to `work-03`, so a restart should agree with the corrected class rather than undo it, but verify.

## 9. Verification

### Running the end-state Job

`kubernetes/operators/rook-ceph/cluster/app/ceph-endstate-verify.yaml` defines `Job/rook-ceph-endstate-verify-v1`. It runs read-only assertions, prints `PASS:` or `FAIL:` for each check, and exits non-zero if any check fails.

```bash
kubectl -n rook-ceph wait --for=condition=complete job/rook-ceph-endstate-verify-v1 --timeout=600s
kubectl -n rook-ceph logs job/rook-ceph-endstate-verify-v1
```

A passing run ends with `RESULT: PASS (all checks passed)`. A failing run ends with `RESULT: FAIL` and lists the failed checks with their observed output.

### What the Job asserts

- `ceph health --format=json` status is `HEALTH_WARN`.
- `AUTH_INSECURE_CLIENT_KEY_TYPE` is present, unmuted, and count 4.
- `AUTH_INSECURE_KEYS_ALLOWED` and `AUTH_INSECURE_KEYS_CREATABLE` are present and muted.
- `BLUESTORE_SLOW_OP_ALERT` is present as the accepted residual.
- `RECENT_MGR_MODULE_CRASH` is absent.
- No health code outside {`AUTH_INSECURE_CLIENT_KEY_TYPE`, `AUTH_INSECURE_KEYS_ALLOWED`, `AUTH_INSECURE_KEYS_CREATABLE`, `BLUESTORE_SLOW_OP_ALERT`} is present. The transient `SLOW_OPS` check is tolerated with a comment, see section 1.
- `ceph mgr module ls` does not list `rook` as enabled.
- Unarchived crash count is 0 (`ceph crash ls-new --format=json` has length 0).
- `osd.4` to `osd.7` sit under `default~hdd`; `osd.3` and `osd.8` under `default~ssd` in `ceph osd crush tree --show-shadow`.
- Both pool rules take `default~hdd` and resolve to a canonical `ceph-blockpool-*` rule.
- `ceph health detail` does not contain `PG_DEGRADED`, `PG_AVAILABILITY`, or `PG_DAMAGED`.
- `ceph osd tree` shows `osd.4` to `osd.7` with class `hdd`.

### Accepted-warning note

The verification Job asserts the accepted end state described in section 1, not the plan's original literal "exactly 3 warnings" target. Task 7 returned NO-GO for the slow-op OSD, so `BLUESTORE_SLOW_OP_ALERT` is an accepted fourth code. The only genuinely unresolved warning is `AUTH_INSECURE_CLIENT_KEY_TYPE`, and it is kernel-gated per section 2.
