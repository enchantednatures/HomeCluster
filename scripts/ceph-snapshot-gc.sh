#!/usr/bin/env bash
#
# ceph-snapshot-gc.sh - reconcile orphaned Rook-Ceph CSI snapshots.
#
# A VolumeSnapshotContent (VSC) whose VolumeSnapshot (VS) no longer exists is
# orphaned. Because most of these VSCs use deletionPolicy=Retain, deleting the
# VSC does not remove the backing RBD image, so csi-snap-* images accumulate in
# the pool and keep consuming space.
#
# The inventory is read-only. The apply mode deletes only snapshot images whose
# UUID is not referenced by any live VSC, so live VolumeSnapshots are preserved.
#
# Usage:
#   ./scripts/ceph-snapshot-gc.sh inventory
#   ./scripts/ceph-snapshot-gc.sh apply --yes [--limit N] [--vsc]
#
# Environment:
#   POOL          Ceph pool to scan (default: ceph-blockpool)
#   PARALLEL      concurrent deletions inside the toolbox (default: 4)
#   TIMEOUT       per-image timeout in seconds (default: 300)
#   WORKDIR       state and log directory (default: /tmp/ceph-snapshot-gc)

set -o errexit
set -o pipefail

POOL="${POOL:-ceph-blockpool}"
TOOLS_NS="${TOOLS_NS:-rook-ceph}"
TOOLS_DEPLOY="${TOOLS_DEPLOY:-rook-ceph-tools}"
WORKDIR="${WORKDIR:-/tmp/ceph-snapshot-gc}"
PARALLEL="${PARALLEL:-4}"
TIMEOUT="${TIMEOUT:-300}"

MODE="${1:-inventory}"
shift || true

APPLY=false
DELETE_VSC=false
LIMIT=0
for arg in "$@"; do
    case "$arg" in
        --yes) APPLY=true ;;
        --vsc) DELETE_VSC=true ;;
        --limit=*) LIMIT="${arg#*=}" ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

log() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
}

toolbox() {
    kubectl -n "$TOOLS_NS" exec "deploy/$TOOLS_DEPLOY" -- "$@"
}

inventory() {
    mkdir -p "$WORKDIR"
    log "collecting VolumeSnapshots and VolumeSnapshotContents"
    kubectl get volumesnapshot -A -o json > "$WORKDIR/vs.json"
    kubectl get volumesnapshotcontent -o json > "$WORKDIR/vsc.json"

    jq -r '[.items[].metadata.uid]' "$WORKDIR/vs.json" > "$WORKDIR/vs-uids.json"

    # VSCs with no owning VS.
    jq -r --slurpfile vs "$WORKDIR/vs-uids.json" '
        .items[]
        | select(.spec.volumeSnapshotRef.uid as $u | ($vs[0] | index($u)) | not)
        | .metadata.name
    ' "$WORKDIR/vsc.json" | sort > "$WORKDIR/orphan-vsc.txt"

    # Snapshot handles that belong to a live VS. Never delete these images.
    jq -r --slurpfile vs "$WORKDIR/vs-uids.json" '
        .items[]
        | select(.spec.volumeSnapshotRef.uid as $u | ($vs[0] | index($u)))
        | .status.snapshotHandle // empty
    ' "$WORKDIR/vsc.json" \
        | sed -E 's/.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/\1/' \
        | sort -u > "$WORKDIR/keep-uuids.txt"

    toolbox rbd ls -p "$POOL" \
        | grep '^csi-snap-' \
        | sed 's/^csi-snap-//' \
        | sort -u > "$WORKDIR/all-uuids.txt"

    comm -23 "$WORKDIR/all-uuids.txt" "$WORKDIR/keep-uuids.txt" > "$WORKDIR/gc-uuids.txt"
    sed 's/^/csi-snap-/' "$WORKDIR/gc-uuids.txt" > "$WORKDIR/gc-images.txt"

    log "pool:                  $POOL"
    log "live snapshot handles: $(wc -l < "$WORKDIR/keep-uuids.txt")"
    log "images in pool:        $(wc -l < "$WORKDIR/all-uuids.txt")"
    log "orphan VSCs:           $(wc -l < "$WORKDIR/orphan-vsc.txt")"
    log "images to delete:      $(wc -l < "$WORKDIR/gc-images.txt")"
    log "inventory written to:  $WORKDIR"
}

apply_images() {
    if [[ ! -s "$WORKDIR/gc-images.txt" ]]; then
        inventory
    fi

    if [[ "$APPLY" != true ]]; then
        log "refusing to delete without --yes"
        exit 3
    fi

    log "copying image list into the toolbox"
    kubectl -n "$TOOLS_NS" exec -i "deploy/$TOOLS_DEPLOY" -- \
        bash -c 'cat > /tmp/ceph-snapshot-gc.txt' < "$WORKDIR/gc-images.txt"

    cat > "$WORKDIR/delete.sh" <<'EOS'
#!/usr/bin/env bash
set -o pipefail
pool="$1"
par="$2"
tmo="$3"
limit="$4"
src=/tmp/ceph-snapshot-gc.txt
batch=/tmp/ceph-snapshot-gc.batch
if [[ "$limit" -gt 0 ]]; then
    head -n "$limit" "$src" > "$batch"
else
    cp "$src" "$batch"
fi
export pool tmo
xargs -P "$par" -I{} bash -c '
    img="{}"
    if timeout --kill-after=10 "$tmo" rbd snap purge "$pool/$img" >/dev/null 2>&1; then
        if timeout --kill-after=10 "$tmo" rbd rm --no-progress "$pool/$img" >/dev/null 2>&1; then
            echo "OK $img"
        else
            echo "FAIL_RM $img"
        fi
    else
        echo "SKIP_PROTECTED_OR_MISSING $img"
    fi
' < "$batch"
EOS

    log "starting deletion (parallel=$PARALLEL timeout=${TIMEOUT}s limit=${LIMIT})"
    kubectl -n "$TOOLS_NS" exec -i "deploy/$TOOLS_DEPLOY" -- \
        bash -s -- "$POOL" "$PARALLEL" "$TIMEOUT" "$LIMIT" < "$WORKDIR/delete.sh" \
        | tee "$WORKDIR/apply.log"
}

delete_vscs() {
    if [[ ! -s "$WORKDIR/orphan-vsc.txt" ]]; then
        log "no orphan VSCs in inventory"
        return 0
    fi

    log "deleting $(wc -l < "$WORKDIR/orphan-vsc.txt") orphan VSCs"
    xargs -a "$WORKDIR/orphan-vsc.txt" -n 100 \
        kubectl delete volumesnapshotcontent --wait=false
}

case "$MODE" in
    inventory)
        inventory
        ;;
    apply)
        apply_images
        if [[ "$DELETE_VSC" == true ]]; then
            delete_vscs
        fi
        ;;
    *)
        echo "usage: $0 {inventory|apply --yes [--limit N] [--vsc]}" >&2
        exit 2
        ;;
esac
