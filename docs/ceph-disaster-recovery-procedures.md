# Ceph Disaster Recovery Procedures

## Scenario 1: Complete Kubernetes Cluster Rebuild (Same Hardware)

### Prerequisites
- [ ] Physical disks remain intact and accessible
- [ ] Node hostnames remain identical
- [ ] Device paths are consistent (`/dev/sd*`, `/dev/nvme*`)
- [ ] `/var/lib/rook` directories are preserved (if possible)

### Recovery Steps

#### 1. Rebuild Kubernetes Cluster
```bash
# Use your Talos/Terraform setup to rebuild the cluster
# Ensure node names match previous deployment
```

#### 2. Verify Storage Devices
```bash
# On each node, verify Ceph devices are detected
lsblk | grep -E "sd[b-z]|nvme[0-9]"

# Check for Ceph signatures
for dev in /dev/sd[b-z] /dev/nvme[0-9]*; do
  if [ -b "$dev" ]; then
    echo "=== $dev ==="
    ceph-volume lvm list $dev 2>/dev/null || echo "No Ceph data found"
  fi
done
```

#### 3. Deploy Rook Operator
```bash
# Apply operator configuration
kubectl apply -f kubernetes/operators/rook-ceph/operator/

# Wait for operator readiness
kubectl -n rook-ceph wait --for=condition=Ready pod -l app=rook-ceph-operator --timeout=300s
```

#### 4. Deploy Ceph Cluster
```bash
# Apply cluster configuration
kubectl apply -f kubernetes/operators/rook-ceph/cluster/

# Monitor cluster recovery
kubectl -n rook-ceph get cephcluster rook-ceph -w
```

#### 5. Verify Recovery
```bash
# Check cluster health
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph fs status

# Verify storage classes
kubectl get storageclass | grep ceph

# Test volume provisioning
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-recovery-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-recovery-pvc
kubectl delete pvc test-recovery-pvc
```

## Scenario 2: Partial Node Failure

### If 1-2 nodes are lost but cluster remains operational:

```bash
# Check cluster health
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status

# Identify failed OSDs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree

# Remove failed OSDs if needed
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out <osd-id>
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd rm <osd-id>
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph auth del osd.<osd-id>

# Allow new OSDs to be created on replacement nodes
# Rook will automatically detect and add new devices
```

## Scenario 3: Complete Data Loss (Restore from Backup)

### If physical disks are lost and you need to restore from backups:

```bash
# 1. Deploy fresh Ceph cluster
kubectl apply -f kubernetes/operators/rook-ceph/

# 2. Wait for cluster to be healthy
kubectl -n rook-ceph wait --for=condition=Ready cephcluster/rook-ceph --timeout=600s

# 3. Restore from volume snapshots
# List available snapshots
kubectl get volumesnapshot --all-namespaces

# Restore specific volumes
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
  namespace: target-namespace
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: 10Gi
  dataSource:
    name: source-snapshot-name
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF
```

## Monitoring and Alerting

### Key Metrics to Monitor
```bash
# Cluster health
ceph status
ceph health detail

# Storage utilization
ceph df
ceph osd df

# Performance metrics
ceph osd perf
ceph pg stat

# Network connectivity
ceph mon stat
```

### Critical Alerts to Configure
1. **Cluster Health**: HEALTH_WARN or HEALTH_ERR
2. **OSD Status**: OSDs down/out for > 5 minutes
3. **Storage Capacity**: > 85% full
4. **Network Issues**: Monitor connectivity failures
5. **Backup Failures**: Failed snapshot creation

## Prevention Best Practices

### 1. Regular Testing
- Monthly disaster recovery drills
- Quarterly backup restoration tests
- Continuous monitoring of cluster health

### 2. Documentation
- Maintain updated recovery procedures
- Document all configuration changes
- Keep hardware inventory current

### 3. Monitoring
- Set up comprehensive alerting
- Regular health checks
- Performance baseline monitoring

### 4. Backup Strategy
- Daily volume snapshots
- Weekly cluster metadata backups
- Offsite backup storage
- Retention policies (30 days minimum)