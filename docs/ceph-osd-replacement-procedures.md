# Ceph OSD Replacement Procedures

## Overview
This document provides detailed procedures for safely removing failed OSDs from the Rook Ceph cluster and rebuilding them. These procedures are designed for the HomeCluster setup with 3 nodes using Ceph v19.2.3.

## Prerequisites
- Access to Kubernetes cluster with Rook Ceph deployed
- Ceph toolbox pod running
- Understanding of cluster topology (3 nodes: work-00, work-01, work-02)
- Backup verification completed

## Phase 1: Identifying Failed OSDs

### 1.1 Access Ceph Toolbox
```bash
# Verify toolbox is running
kubectl get pods -n rook-ceph -l app=rook-ceph-tools

# If not running, apply the toolbox configuration
kubectl apply -f kubernetes/operators/rook-ceph/cluster/app/ceph-toolbox.yaml

# Wait for toolbox to be ready
kubectl wait --for=condition=ready pod -l app=rook-ceph-tools -n rook-ceph --timeout=300s

# Access the toolbox
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash
```

### 1.2 Comprehensive Cluster Health Assessment
```bash
# Inside the toolbox container:

# 1. Check overall cluster status
ceph status

# 2. Check detailed health information
ceph health detail

# 3. Identify failed/problematic OSDs
ceph osd tree
ceph osd stat
ceph osd dump

# 4. Check OSD specific issues
ceph osd perf
ceph osd df

# 5. Look for OSDs that are down, out, or have issues
ceph osd ls
ceph osd metadata

# 6. Check placement group status
ceph pg stat
ceph pg dump | grep -v "active+clean"

# 7. Identify OSDs with high latency or errors
ceph osd perf | sort -k2 -n
```

### 1.3 Identify Specific Failed OSDs
```bash
# Find OSDs that are down or out
ceph osd tree | grep -E "(down|out)"

# Check for OSDs with errors
ceph health detail | grep -i osd

# List OSDs by status
for state in up down in out; do
    echo "=== OSDs that are $state ==="
    ceph osd ls-tree --format=json | jq -r ".[] | select(.status == \"$state\") | .name"
done

# Get detailed information about a specific OSD
# Replace X with the actual OSD ID
ceph osd find X
ceph osd metadata X
```

## Phase 2: Pre-Removal Safety Checks

### 2.1 Verify Cluster Can Handle OSD Loss
```bash
# Check current cluster capacity and usage
ceph df

# Verify we have enough replicas for data safety
ceph osd pool ls detail

# Check if removing OSDs will maintain minimum replica count
# For your 3-node cluster with replica 3, you need all nodes healthy
ceph pg dump | awk '{print $1, $15, $16, $17}' | grep -v "^pg_stat"

# Check if cluster can rebalance with remaining OSDs
ceph osd df | grep -E "USE%|AVAIL"

# Verify no single point of failure
ceph osd crush tree
```

### 2.2 Set Cluster Flags (Protection Mode)
```bash
# Prevent automatic rebalancing during maintenance
ceph osd set noout
ceph osd set norebalance
ceph osd set norecover
ceph osd set nobackfill

# Optional: prevent new writes during critical operations
# ceph osd set noscrub
# ceph osd set nodeep-scrub

# Verify flags are set
ceph osd dump | grep flags
```

### 2.3 Document Current State
```bash
# Save current cluster state for reference
ceph status > /tmp/ceph_status_before_removal.txt
ceph osd tree > /tmp/ceph_osd_tree_before_removal.txt
ceph pg dump > /tmp/ceph_pg_dump_before_removal.txt
ceph osd df > /tmp/ceph_osd_df_before_removal.txt

# Show files created
ls -la /tmp/ceph_*_before_removal.txt
```

## Phase 3: Safe OSD Removal Procedures

### 3.1 Mark OSDs as Out (Gradual Approach)
```bash
# For each failed OSD, mark it as out first
# Replace X with the actual OSD ID
OSD_ID=X
echo "Processing OSD $OSD_ID"

# Check current status
ceph osd find $OSD_ID

# Mark as out (triggers data migration)
ceph osd out $OSD_ID

# Monitor rebalancing progress
watch ceph status
# Or check specific metrics:
ceph pg stat
ceph osd df
```

### 3.2 Wait for Data Migration
```bash
# Monitor until all PGs are active+clean
while ! ceph pg stat | grep -q "active+clean"; do
    echo "Waiting for rebalancing to complete..."
    ceph pg stat
    sleep 30
done

echo "Data migration completed successfully"
```

### 3.3 Stop OSD Daemon
```bash
# Stop the OSD daemon (replace X with OSD ID)
OSD_ID=X

# Stop the OSD
ceph osd down $OSD_ID

# Verify it's stopped
ceph osd tree | grep osd.$OSD_ID
```

### 3.4 Remove OSD from CRUSH Map
```bash
# Remove OSD from CRUSH map
ceph osd crush remove osd.$OSD_ID

# Verify removal
ceph osd crush tree
```

### 3.5 Delete OSD Authentication
```bash
# Delete OSD authentication keys
ceph auth del osd.$OSD_ID

# Verify deletion
ceph auth list | grep osd.$OSD_ID
```

### 3.6 Remove OSD from Cluster
```bash
# Remove OSD from the cluster
ceph osd rm $OSD_ID

# Verify removal
ceph osd ls | grep $OSD_ID
ceph osd tree
```

## Phase 4: Kubernetes-Level Cleanup

### 4.1 Identify and Remove Kubernetes Resources
```bash
# Exit the toolbox first
exit

# Find the failed OSD deployment
kubectl get deployments -n rook-ceph | grep osd

# Find the specific OSD pod and deployment
OSD_ID=X  # Replace with actual OSD ID
kubectl get pods -n rook-ceph | grep "osd-$OSD_ID"

# Get the deployment name
OSD_DEPLOYMENT=$(kubectl get deployments -n rook-ceph -o name | grep "osd-$OSD_ID")
echo "Found deployment: $OSD_DEPLOYMENT"

# Delete the OSD deployment
kubectl delete $OSD_DEPLOYMENT -n rook-ceph

# Remove any stuck pods
kubectl delete pods -n rook-ceph -l "osd=$OSD_ID" --force --grace-period=0

# Clean up any associated jobs
kubectl delete jobs -n rook-ceph | grep "osd-$OSD_ID"
```

### 4.2 Clean Up PVCs and ConfigMaps
```bash
# Find and remove OSD-specific PVCs
kubectl get pvc -n rook-ceph | grep "osd-$OSD_ID"
kubectl delete pvc -n rook-ceph $(kubectl get pvc -n rook-ceph | grep "osd-$OSD_ID" | awk '{print $1}')

# Clean up ConfigMaps
kubectl get configmaps -n rook-ceph | grep "osd-$OSD_ID"
kubectl delete configmaps -n rook-ceph $(kubectl get configmaps -n rook-ceph | grep "osd-$OSD_ID" | awk '{print $1}')
```

## Phase 5: Physical Device Cleanup

### 5.1 Identify the Node and Device
```bash
# From the earlier ceph osd find command, identify which node the OSD was on
# For your cluster, it will be one of: work-00, work-01, work-02
NODE_NAME="work-XX"  # Replace with actual node

# Device path - could be SSD (/dev/sdb) or NVMe (/dev/nvme0n1)
DEVICE_PATH="/dev/sdb"  # Default SSD path

# For NVMe devices, identify the correct path:
# Check NVMe devices on the node
kubectl debug node/$NODE_NAME -it --image=alpine:latest -- chroot /host sh -c "nvme list"

# Common NVMe device paths:
# /dev/nvme0n1, /dev/nvme1n1, /dev/nvme2n1, etc.
DEVICE_PATH="/dev/nvme0n1"  # Update for NVMe devices
```

### 5.2 Clean Device Signatures
```bash
# Option A: Using a privileged pod for device cleanup
cat << 'EOF' > /tmp/device-cleanup-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: device-cleanup
  namespace: rook-ceph
spec:
  nodeSelector:
    kubernetes.io/hostname: NODE_NAME_PLACEHOLDER
  hostNetwork: true
  hostPID: true
  containers:
  - name: device-cleanup
    image: quay.io/ceph/ceph:v19.2.3
    command: ["/bin/bash"]
    args: ["-c", "sleep 3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: dev
      mountPath: /dev
    - name: sys
      mountPath: /sys
  volumes:
  - name: dev
    hostPath:
      path: /dev
  - name: sys
    hostPath:
      path: /sys
  restartPolicy: Never
EOF

# Replace NODE_NAME_PLACEHOLDER with actual node name
sed "s/NODE_NAME_PLACEHOLDER/$NODE_NAME/g" /tmp/device-cleanup-pod.yaml | kubectl apply -f -

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/device-cleanup -n rook-ceph --timeout=300s

# Execute cleanup commands
# For SSD devices:
kubectl exec -n rook-ceph device-cleanup -- sgdisk --zap-all $DEVICE_PATH
kubectl exec -n rook-ceph device-cleanup -- dd if=/dev/zero of=$DEVICE_PATH bs=1M count=100
kubectl exec -n rook-ceph device-cleanup -- wipefs --all $DEVICE_PATH

# For NVMe devices, use NVMe-specific commands:
if [[ $DEVICE_PATH =~ ^/dev/nvme ]]; then
    # NVMe secure erase (preferred method)
    kubectl exec -n rook-ceph device-cleanup -- nvme format -s 1 $DEVICE_PATH  # User data erase
    # OR for cryptographic erase (if supported):
    # kubectl exec -n rook-ceph device-cleanup -- nvme format -s 2 $DEVICE_PATH
else
    # Standard SSD cleanup
    kubectl exec -n rook-ceph device-cleanup -- sgdisk --zap-all $DEVICE_PATH
    kubectl exec -n rook-ceph device-cleanup -- dd if=/dev/zero of=$DEVICE_PATH bs=1M count=100
    kubectl exec -n rook-ceph device-cleanup -- wipefs --all $DEVICE_PATH
fi

# Verify device is clean
kubectl exec -n rook-ceph device-cleanup -- lsblk $DEVICE_PATH
kubectl exec -n rook-ceph device-cleanup -- fdisk -l $DEVICE_PATH 2>/dev/null || echo "fdisk may not work with NVMe partitions"

# For NVMe, also check:
if [[ $DEVICE_PATH =~ ^/dev/nvme ]]; then
    kubectl exec -n rook-ceph device-cleanup -- nvme list-ns $DEVICE_PATH
fi

# Clean up the pod
kubectl delete pod device-cleanup -n rook-ceph
```

## Phase 6: Adding New OSDs

### 6.1 Verify Device Readiness
```bash
# Create verification pod on the target node
cat << EOF > /tmp/device-verify-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: device-verify
  namespace: rook-ceph
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  hostNetwork: true
  containers:
  - name: device-verify
    image: quay.io/ceph/ceph:v19.2.3
    command: ["/bin/bash"]
    args: ["-c", "sleep 300"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: dev
      mountPath: /dev
  volumes:
  - name: dev
    hostPath:
      path: /dev
  restartPolicy: Never
EOF

kubectl apply -f /tmp/device-verify-pod.yaml
kubectl wait --for=condition=ready pod/device-verify -n rook-ceph --timeout=300s

# Verify device is available and clean
kubectl exec -n rook-ceph device-verify -- lsblk $DEVICE_PATH

# Device-specific verification
if [[ $DEVICE_PATH =~ ^/dev/nvme ]]; then
    # NVMe-specific checks
    kubectl exec -n rook-ceph device-verify -- nvme list
    kubectl exec -n rook-ceph device-verify -- nvme id-ctrl $DEVICE_PATH
    kubectl exec -n rook-ceph device-verify -- nvme smart-log $DEVICE_PATH | grep -E "(temperature|available_spare|percentage_used)"
    kubectl exec -n rook-ceph device-verify -- nvme list-ns $DEVICE_PATH
else
    # SSD-specific checks
    kubectl exec -n rook-ceph device-verify -- fdisk -l $DEVICE_PATH 2>/dev/null || echo "Device appears clean"
fi

# Clean up
kubectl delete pod device-verify -n rook-ceph
```

### 6.2 Trigger OSD Recreation
Your Rook configuration should automatically detect the clean device and create a new OSD. Monitor the process:

```bash
# Watch for new OSD preparation
kubectl get pods -n rook-ceph -w | grep prepare

# Monitor OSD creation
kubectl get pods -n rook-ceph -w | grep osd

# Check logs of OSD preparation
kubectl logs -n rook-ceph -l app=rook-ceph-osd-prepare -f
```

### 6.3 Force OSD Recreation (if needed)
```bash
# If automatic detection doesn't work, restart the operator
kubectl rollout restart deployment/rook-ceph-operator -n rook-ceph

# Or delete and recreate the CephCluster resource (more aggressive)
# kubectl delete cephcluster rook-ceph -n rook-ceph
# kubectl apply -f kubernetes/operators/rook-ceph/cluster/app/ceph-cluster.yaml
```

## Phase 7: Cluster Rebalancing

### 7.1 Remove Safety Flags
```bash
# Re-enter toolbox
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash

# Remove maintenance flags to allow rebalancing
ceph osd unset noout
ceph osd unset norebalance
ceph osd unset norecover
ceph osd unset nobackfill

# If you set scrub flags, remove them too
# ceph osd unset noscrub
# ceph osd unset nodeep-scrub

# Verify flags are removed
ceph osd dump | grep flags
```

### 7.2 Monitor Rebalancing
```bash
# Watch cluster rebalance
watch ceph status

# Monitor specific metrics
watch "ceph pg stat; echo; ceph osd df"

# Check rebalancing progress
ceph progress

# Monitor I/O during rebalancing
watch "ceph iostat"
```

### 7.3 Verify New OSD Integration
```bash
# Verify new OSD is in the cluster
ceph osd tree

# Check OSD status
ceph osd stat

# Verify OSD is receiving data
ceph osd df

# Check CRUSH map
ceph osd crush tree
```

## Phase 8: Post-Replacement Validation

### 8.1 Comprehensive Health Check
```bash
# Run the health check script
# (Run this outside the toolbox)
exit  # Exit toolbox first
./scripts/ceph-health-check.sh
```

### 8.2 Performance Validation
```bash
# Back in toolbox
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash

# Check cluster performance
ceph osd perf

# Verify balanced data distribution
ceph osd df | sort -k7 -n

# Check for any PG imbalances
ceph pg ls | awk '{print $1, $15}' | sort | uniq -c | sort -n
```

### 8.3 Storage Class Testing
```bash
# Exit toolbox
exit

# Create a test PVC to verify functionality
cat << EOF > /tmp/test-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ceph-block
EOF

kubectl apply -f /tmp/test-pvc.yaml

# Verify PVC is bound
kubectl get pvc test-ceph-pvc

# Create a test pod to use the PVC
cat << EOF > /tmp/test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-ceph-pod
  namespace: default
spec:
  containers:
  - name: test-container
    image: busybox
    command: ["/bin/sh"]
    args: ["-c", "echo 'Test file' > /mnt/test.txt && sleep 300"]
    volumeMounts:
    - name: test-volume
      mountPath: /mnt
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: test-ceph-pvc
EOF

kubectl apply -f /tmp/test-pod.yaml

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/test-ceph-pod --timeout=300s

# Verify file was written
kubectl exec test-ceph-pod -- cat /mnt/test.txt

# Clean up test resources
kubectl delete pod test-ceph-pod
kubectl delete pvc test-ceph-pvc
```

## Phase 9: Monitoring and Alerting

### 9.1 Set Up Monitoring
```bash
# Verify monitoring is working
kubectl get servicemonitor -n rook-ceph

# Check if Prometheus is scraping Ceph metrics
# (This assumes you have Prometheus deployed)
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &
# Open http://localhost:9090 and search for "ceph_" metrics
```

### 9.2 Document the Changes
```bash
# Create a record of what was done
cat << EOF > /tmp/osd-replacement-record-$(date +%Y%m%d-%H%M%S).md
# OSD Replacement Record

## Date: $(date)
## Operator: $(whoami)

### OSDs Replaced:
- OSD ID: $OSD_ID
- Node: $NODE_NAME
- Device: $DEVICE_PATH
- Reason: [Add reason for replacement]

### Actions Taken:
1. Marked OSD as out
2. Waited for data migration
3. Removed OSD from cluster
4. Cleaned up Kubernetes resources
5. Wiped device signatures
6. Allowed automatic OSD recreation
7. Verified cluster health

### Final Status:
- Cluster Health: $(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph health)
- OSD Count: $(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd stat)
- Storage Usage: $(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph df | grep "TOTAL")

### Notes:
[Add any additional notes or observations]
EOF

echo "Replacement record created: /tmp/osd-replacement-record-$(date +%Y%m%d-%H%M%S).md"
```

## Emergency Procedures

### Multiple OSD Failures
If multiple OSDs fail simultaneously:

1. **DO NOT** remove all failed OSDs at once
2. Remove one OSD at a time
3. Wait for each rebalancing to complete before proceeding
4. If more than 1/3 of OSDs fail, consider cluster rebuild

### Recovery from Failed Replacement
If OSD replacement fails:

```bash
# Check operator logs
kubectl logs -n rook-ceph deployment/rook-ceph-operator --tail=100

# Check device preparation logs
kubectl logs -n rook-ceph -l app=rook-ceph-osd-prepare --tail=100

# Force device cleanup and retry
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash
# Run device cleanup commands again

# Restart operator if needed
kubectl rollout restart deployment/rook-ceph-operator -n rook-ceph
```

### Data Loss Prevention
- Always verify cluster has sufficient replicas before OSD removal
- Never remove more OSDs than your replica count can handle
- Keep regular backups of critical data
- Monitor cluster health continuously during operations

## Troubleshooting Commands

### Common Issues and Solutions

#### OSD Won't Start After Replacement
```bash
# Check device permissions
kubectl exec -n rook-ceph device-verify -- ls -la /dev/sdb*

# Verify device is completely clean
kubectl exec -n rook-ceph device-verify -- dd if=/dev/sdb bs=1M count=1 | hexdump -C

# Check operator logs for errors
kubectl logs -n rook-ceph deployment/rook-ceph-operator | grep -i error
```

#### Stuck Placement Groups
```bash
# Force PG recovery
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph pg force-recovery

# Query stuck PGs
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph pg dump | grep -v "active+clean"
```

#### Slow Rebalancing
```bash
# Increase recovery rates (temporary)
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set global osd_max_backfills 4
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set global osd_recovery_max_active 6

# Reset to defaults after rebalancing
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config rm global osd_max_backfills
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config rm global osd_recovery_max_active
```

## Safety Checklist

Before starting OSD replacement:
- [ ] Cluster health is HEALTH_OK or HEALTH_WARN (not HEALTH_ERR)
- [ ] Sufficient free space for rebalancing (at least 20% free)
- [ ] All other OSDs are healthy
- [ ] Recent backup verification completed
- [ ] Maintenance window scheduled
- [ ] Emergency contact information available

During OSD replacement:
- [ ] Only one OSD being processed at a time
- [ ] Monitoring cluster health continuously
- [ ] Data migration completing successfully
- [ ] No new errors appearing in logs

After OSD replacement:
- [ ] Cluster health returns to HEALTH_OK
- [ ] All PGs are active+clean
- [ ] Storage usage is balanced
- [ ] Test PVC creation and mounting works
- [ ] Monitoring and alerting functional

This document should be used as a reference during OSD replacement operations. Always adapt procedures based on your specific situation and cluster state.