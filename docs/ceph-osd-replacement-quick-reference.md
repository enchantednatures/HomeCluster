# Ceph OSD Replacement Quick Reference

## Emergency Commands

### Immediate Health Check
```bash
# Quick cluster status
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph status

# Check for failed OSDs
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd tree | grep -E "(down|out)"

# Check cluster health detail
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph health detail
```

### Automated Replacement Workflow
```bash
# Start interactive replacement wizard
./scripts/ceph-osd-replacement.sh replace

# Or check health first
./scripts/ceph-osd-replacement.sh check-health
./scripts/ceph-osd-replacement.sh identify-failed
```

## Manual Step-by-Step (Emergency Procedure)

### 1. Prepare Environment
```bash
# Ensure toolbox is running
kubectl apply -f kubernetes/operators/rook-ceph/cluster/app/ceph-toolbox.yaml
kubectl wait --for=condition=ready pod -l app=rook-ceph-tools -n rook-ceph --timeout=300s

# Enter toolbox
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash
```

### 2. Safety Checks (Inside Toolbox)
```bash
# Check cluster can handle OSD loss
ceph status
ceph df                    # Ensure <80% usage
ceph osd stat             # Count healthy OSDs
ceph pg stat              # Verify PGs are healthy

# Set protection flags
ceph osd set noout
ceph osd set norebalance
ceph osd set norecover
ceph osd set nobackfill
```

### 3. Remove Failed OSD (Replace X with OSD ID)
```bash
OSD_ID=X

# Mark as out and wait for migration
ceph osd out $OSD_ID
# WAIT for all PGs to be active+clean before proceeding

# Remove from cluster
ceph osd down $OSD_ID
ceph osd crush remove osd.$OSD_ID
ceph auth del osd.$OSD_ID
ceph osd rm $OSD_ID

# Exit toolbox
exit
```

### 4. Clean Kubernetes Resources
```bash
# Find and delete OSD deployment
kubectl delete deployment -n rook-ceph $(kubectl get deployments -n rook-ceph -o name | grep "osd-$OSD_ID")

# Force delete stuck pods
kubectl delete pods -n rook-ceph -l "osd=$OSD_ID" --force --grace-period=0

# Clean up PVCs and ConfigMaps
kubectl delete pvc -n rook-ceph $(kubectl get pvc -n rook-ceph | grep "osd-$OSD_ID" | awk '{print $1}')
kubectl delete configmaps -n rook-ceph $(kubectl get configmaps -n rook-ceph | grep "osd-$OSD_ID" | awk '{print $1}')
```

### 5. Clean Physical Device
```bash
# Create cleanup pod (replace NODE_NAME)
NODE_NAME="work-XX"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: device-cleanup
  namespace: rook-ceph
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  hostNetwork: true
  hostPID: true
  containers:
  - name: device-cleanup
    image: quay.io/ceph/ceph:v19.2.3
    command: ["/bin/bash", "-c", "sleep 3600"]
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
  tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists
EOF

# Wait and clean device
kubectl wait --for=condition=ready pod/device-cleanup -n rook-ceph --timeout=300s
kubectl exec -n rook-ceph device-cleanup -- sgdisk --zap-all /dev/sdb
kubectl exec -n rook-ceph device-cleanup -- dd if=/dev/zero of=/dev/sdb bs=1M count=100
kubectl exec -n rook-ceph device-cleanup -- wipefs --all /dev/sdb

# Verify and cleanup
kubectl exec -n rook-ceph device-cleanup -- lsblk /dev/sdb
kubectl delete pod device-cleanup -n rook-ceph
```

### 6. Enable Rebalancing and Monitor
```bash
# Re-enter toolbox
kubectl -n rook-ceph exec -it deployment/rook-ceph-tools -- bash

# Remove protection flags
ceph osd unset noout
ceph osd unset norebalance
ceph osd unset norecover
ceph osd unset nobackfill

# Monitor new OSD creation
watch ceph osd tree
# Exit and monitor from outside
exit

# Watch OSD preparation
kubectl logs -n rook-ceph -l app=rook-ceph-osd-prepare -f
```

### 7. Final Validation
```bash
# Check cluster health
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph status

# Test storage functionality
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
  storageClassName: ceph-block
EOF

kubectl get pvc test-ceph-pvc
kubectl delete pvc test-ceph-pvc
```

## Troubleshooting

### OSD Won't Start After Replacement
```bash
# Check operator logs
kubectl logs -n rook-ceph deployment/rook-ceph-operator --tail=50

# Check device preparation
kubectl logs -n rook-ceph -l app=rook-ceph-osd-prepare --tail=50

# Restart operator if needed
kubectl rollout restart deployment/rook-ceph-operator -n rook-ceph
```

### Stuck Placement Groups
```bash
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- bash
ceph pg dump | grep -v "active+clean"
ceph pg force-recovery
```

### Multiple OSD Failures
- Only replace ONE OSD at a time
- Wait for full rebalancing before proceeding to next
- If >1/3 of OSDs fail, consider full cluster rebuild

### Data Migration Taking Too Long
```bash
# Temporarily increase recovery rates (inside toolbox)
ceph config set global osd_max_backfills 4
ceph config set global osd_recovery_max_active 6

# Reset after rebalancing
ceph config rm global osd_max_backfills
ceph config rm global osd_recovery_max_active
```

## Safety Checklist

**Before Starting:**
- [ ] Cluster health is HEALTH_OK or HEALTH_WARN only
- [ ] Storage usage <80%
- [ ] At least 2/3 of OSDs are healthy
- [ ] Recent backup verified
- [ ] Maintenance window scheduled

**During Replacement:**
- [ ] Only one OSD being replaced at a time
- [ ] Data migration completed before proceeding
- [ ] No new errors in logs
- [ ] Monitoring cluster continuously

**After Replacement:**
- [ ] Cluster health returns to HEALTH_OK
- [ ] All PGs are active+clean
- [ ] Storage usage is balanced
- [ ] Test PVC creation works
- [ ] Document the change

## Emergency Contacts

- **Cluster Health Check:** `./scripts/ceph-health-check.sh`
- **Full Documentation:** `docs/ceph-osd-replacement-procedures.md`
- **Automated Script:** `./scripts/ceph-osd-replacement.sh replace`

## Recovery from Failed Replacement

If replacement fails completely:
1. Check if data is still safe: `ceph status`
2. If cluster is healthy, retry the replacement
3. If cluster is degraded, focus on restoring health first
4. Consider restoring from backup if data integrity is compromised

**Remember:** Always prioritize data safety over speed. When in doubt, stop and assess.