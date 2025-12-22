# Ceph NVMe Drive Setup Guide

## Overview

This guide provides comprehensive instructions for setting up and optimizing NVMe drives for Ceph OSDs in the HomeCluster. NVMe drives offer significantly higher performance than traditional SSDs, making them ideal for Ceph metadata, WAL, and high-performance data storage.

## Prerequisites

- NVMe drives with PCIe 3.0/4.0/5.0 interface
- Minimum 500GB capacity per drive (1TB+ recommended)
- PCIe lanes: 4x minimum, 8x+ preferred
- Firmware updated to latest version
- Compatible with your Proxmox/Talos setup

## NVMe Device Discovery

### 1. Identify NVMe Devices on Nodes

```bash
# Check all nodes for NVMe devices
for node in work-00 work-01 work-02; do
    echo "=== NVMe devices on $node ==="
    kubectl debug node/$node -it --image=alpine:latest -- chroot /host sh -c "
        ls -la /dev/nvme*
        nvme list
        lspci | grep -i nvme
    "
done
```

### 2. NVMe Device Information

```bash
# Get detailed NVMe device information
nvme list
nvme id-ctrl /dev/nvme0
nvme smart-log /dev/nvme0

# Check PCIe information
lspci -vvv -s $(lspci | grep -i nvme | cut -d' ' -f1)
```

### 3. Device Health and Firmware

```bash
# Check NVMe health status
nvme smart-log /dev/nvme0 | grep -E "(temperature|available_spare|percentage_used|media_errors)"

# Check firmware version
nvme id-ctrl /dev/nvme0 | grep -E "(fr|mn)"

# Check for NVMe namespaces
nvme list-ns /dev/nvme0
```

## NVMe Device Preparation

### 1. Partitioning Strategy

For Ceph OSDs, use GPT partitioning with proper alignment:

```bash
# Create GPT partition table (replace /dev/nvme0n1 with your device)
parted /dev/nvme0n1 mklabel gpt

# Create single partition with optimal alignment
# NVMe optimal I/O size is typically 512KB or 4KB
parted -a optimal /dev/nvme0n1 mkpart primary 0% 100%
```

### 2. Device Cleanup and Preparation

```bash
# Secure erase NVMe device (if supported)
nvme format -s 1 /dev/nvme0n1  # User data erase
# OR
nvme format -s 2 /dev/nvme0n1  # Cryptographic erase (if supported)

# Verify device is clean
blkid /dev/nvme0n1p1 || echo "Device is clean"
```

### 3. Performance Verification

```bash
# Test NVMe performance
fio --name=nvme-test --rw=randread --bs=4k --numjobs=8 --runtime=30 --time_based --filename=/dev/nvme0n1p1

# Check I/O scheduler (should be 'none' for NVMe)
cat /sys/block/nvme0n1/queue/scheduler
```

## Ceph Configuration for NVMe

### 1. NVMe-Specific CephCluster Configuration

Update your `kubernetes/operators/rook-ceph/cluster/app/ceph-cluster.yaml`:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  storage:
    useAllNodes: true
    useAllDevices: true
    deviceFilter: "^nvme[0-9]n[0-9]$"  # Only NVMe devices
    config:
      # NVMe-optimized BlueStore settings
      bluestoreBlockSize: "4G"          # Larger blocks for NVMe
      bluestoreBlockDbSize: "1G"        # Larger DB for better performance
      bluestoreBlockWalSize: "1G"       # Larger WAL for NVMe speed
      bluestoreCacheSize: "3G"          # Larger cache for NVMe
      bluestoreCacheMetaRatio: "0.8"    # More cache for metadata
      bluestoreMaxBlobSize: "2G"        # Larger blobs for NVMe
      bluestoreMinAllocSize: "4K"       # Match NVMe sector size
      bluestoreMaxAllocSize: "16M"      # Larger allocations
      bluestoreCompressionMode: "none"  # Disable compression for max performance
      bluestoreCacheAutotune: "true"    # Auto-tune cache
      bluestoreCacheAutotuneInterval: "3600"  # Hourly tuning
```

### 2. CRUSH Map Configuration for NVMe

Create NVMe-specific CRUSH rules:

```bash
# Access Ceph toolbox
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash

# Create NVMe device class
ceph osd crush device-class create nvme

# Set device class for NVMe OSDs
for osd in $(ceph osd ls); do
    device=$(ceph osd metadata $osd | jq -r '.device')
    if [[ $device =~ ^nvme ]]; then
        ceph osd crush set-device-class nvme $osd
    fi
done

# Create NVMe-specific CRUSH rule
ceph osd crush rule create-replicated nvme-rule default host nvme

# Verify CRUSH configuration
ceph osd crush tree
ceph osd crush rule ls
```

### 3. NVMe-Optimized Storage Classes

Create `kubernetes/operators/rook-ceph/cluster/app/storage-classes-nvme.yaml`:

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-nvme-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: nvme-pool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-nvme-ssd
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: nvme-pool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
  compression: none  # Disable compression for max performance
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: nvme-pool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
  deviceClass: nvme  # Use NVMe device class
  parameters:
    compression_mode: none  # Disable compression
    pg_autoscale_mode: on
    pg_num_min: 32
    target_size_ratio: 0.8
```

## Performance Tuning for NVMe

### 1. Kernel Parameters

Add to your Talos machine config or node tuning:

```yaml
# Talos machine config snippet
machine:
  sysctls:
    # NVMe-specific optimizations
    vm.dirty_background_ratio: 5
    vm.dirty_ratio: 10
    vm.dirty_expire_centisecs: 3000
    vm.dirty_writeback_centisecs: 500
    # Increase I/O queue depths
    kernel.sched_min_granularity_ns: 10000000
    kernel.sched_wakeup_granularity_ns: 15000000
```

### 2. PCIe Optimizations

```bash
# Disable PCIe ASPM for maximum performance
echo "performance" > /sys/bus/pci/devices/0000:XX:XX.X/link_power_management

# Check PCIe link status
lspci -vvv -s XX:XX.X | grep -A 10 "LnkSta"

# Set PCIe MPS (Max Payload Size)
setpci -s XX:XX.X CAP_EXP+8.w=0x2  # 512 bytes
```

### 3. NUMA Awareness

For multi-socket systems:

```bash
# Check NUMA topology
numactl --hardware

# Pin Ceph OSDs to specific NUMA nodes
# In systemd service override or Rook configuration
numactl --cpunodebind=0 --membind=0 ceph-osd ...
```

## Monitoring NVMe Performance

### 1. Prometheus Metrics

Add NVMe metrics collection:

```yaml
# Add to your Prometheus configuration
scrape_configs:
  - job_name: 'nvme'
    static_configs:
      - targets: ['work-00:9633', 'work-01:9633', 'work-02:9633']
    metrics_path: /metrics/nvme
```

### 2. Grafana Dashboard

Import Ceph NVMe dashboard with metrics for:
- IOPS (read/write)
- Latency (read/write)
- Bandwidth (read/write)
- Queue depth
- Device utilization
- Temperature
- Wear level

### 3. Alerting Rules

```yaml
# NVMe-specific alerts
groups:
  - name: nvme_alerts
    rules:
      - alert: NVMeHighTemperature
        expr: nvme_temperature > 70
        for: 5m
        labels:
          severity: warning
      - alert: NVMeHighWearLevel
        expr: nvme_wear_level > 90
        for: 5m
        labels:
          severity: critical
```

## Troubleshooting NVMe Issues

### 1. Common Problems

**Slow Performance:**
- Check PCIe link speed: `lspci -vvv | grep -A 10 LnkSta`
- Verify I/O scheduler: `cat /sys/block/nvme0n1/queue/scheduler`
- Check for thermal throttling: `nvme smart-log /dev/nvme0`

**Device Not Detected:**
- Check PCIe slot: `lspci | grep NVMe`
- Verify kernel module: `lsmod | grep nvme`
- Check BIOS settings for PCIe

**Firmware Issues:**
- Update firmware: Check manufacturer tools
- Verify compatibility with Ceph version
- Check for known issues in release notes

### 2. Diagnostic Commands

```bash
# Comprehensive NVMe diagnostics
nvme list
nvme id-ctrl /dev/nvme0
nvme smart-log /dev/nvme0
nvme error-log /dev/nvme0
nvme fw-log /dev/nvme0

# Ceph OSD performance
ceph osd perf
ceph osd df tree

# I/O statistics
iostat -x 1 /dev/nvme0n1
```

### 3. Recovery Procedures

**NVMe Device Failure:**
1. Mark OSD as out: `ceph osd out <osd_id>`
2. Wait for data migration
3. Stop OSD: `ceph osd down <osd_id>`
4. Remove from CRUSH: `ceph osd crush remove osd.<osd_id>`
5. Delete auth: `ceph auth del osd.<osd_id>`
6. Remove OSD: `ceph osd rm <osd_id>`
7. Clean device and redeploy

## Best Practices

### 1. Hardware Selection
- Choose enterprise-grade NVMe drives
- Ensure proper cooling (NVMe can run hot)
- Use drives with power loss protection
- Consider drives with built-in encryption

### 2. Configuration Guidelines
- Use dedicated NVMe for OSD data when possible
- Separate metadata/WAL on fastest NVMe
- Monitor temperature and adjust cooling
- Regular firmware updates

### 3. Maintenance
- Monitor SMART data regularly
- Plan for wear leveling (NVMe has limited writes)
- Backup firmware before updates
- Test performance after configuration changes

## Integration with HomeCluster

### 1. GitOps Workflow
- Store NVMe configurations in git
- Use Kustomize for node-specific overrides
- Monitor changes with Flux

### 2. Backup Considerations
- Include NVMe configurations in backups
- Test restore procedures with NVMe
- Document hardware-specific settings

### 3. Scaling
- Plan NVMe capacity for growth
- Consider mixing NVMe and SSD tiers
- Monitor performance as cluster grows

This guide provides a foundation for deploying high-performance Ceph clusters using NVMe storage. Adjust configurations based on your specific hardware and workload requirements.