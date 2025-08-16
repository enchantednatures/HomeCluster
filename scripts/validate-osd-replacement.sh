#!/bin/bash

# OSD Replacement Validation Script
# This script validates that OSD replacement was successful and cluster is healthy

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="rook-ceph"
TOOLBOX_DEPLOYMENT="deployment/rook-ceph-tools"

print_status() {
    local status=$1
    local message=$2
    case $status in
        "OK") echo -e "${GREEN}✓${NC} $message" ;;
        "WARN") echo -e "${YELLOW}⚠${NC} $message" ;;
        "ERROR") echo -e "${RED}✗${NC} $message" ;;
        "INFO") echo -e "${BLUE}ℹ${NC} $message" ;;
    esac
}

print_header() {
    echo
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo
}

ceph_exec() {
    kubectl -n $NAMESPACE exec $TOOLBOX_DEPLOYMENT -- "$@"
}

print_header "OSD Replacement Validation"

# Check if toolbox is available
if ! kubectl get pods -n $NAMESPACE -l app=rook-ceph-tools | grep -q "Running"; then
    print_status "ERROR" "Ceph toolbox is not running"
    exit 1
fi

# 1. Check overall cluster health
print_header "Cluster Health Validation"

health_status=$(ceph_exec ceph health)
if echo "$health_status" | grep -q "HEALTH_OK"; then
    print_status "OK" "Cluster health: $health_status"
elif echo "$health_status" | grep -q "HEALTH_WARN"; then
    print_status "WARN" "Cluster health: $health_status"
    print_status "INFO" "Checking health details..."
    ceph_exec ceph health detail
else
    print_status "ERROR" "Cluster health: $health_status"
    ceph_exec ceph health detail
    exit 1
fi

# 2. Check OSD status and distribution
print_header "OSD Status Validation"

osd_stat=$(ceph_exec ceph osd stat)
print_status "INFO" "OSD Status: $osd_stat"

# Check OSD tree for proper distribution
print_status "INFO" "OSD Distribution:"
ceph_exec ceph osd tree

# Count OSDs per node
echo
print_status "INFO" "OSDs per node:"
for node in work-00 work-01 work-02; do
    osd_count=$(ceph_exec ceph osd tree | grep "$node" | grep "osd\." | wc -l)
    if [[ $osd_count -eq 1 ]]; then
        print_status "OK" "$node: $osd_count OSD"
    elif [[ $osd_count -eq 0 ]]; then
        print_status "ERROR" "$node: No OSDs found"
    else
        print_status "WARN" "$node: $osd_count OSDs (expected 1)"
    fi
done

# Check for any down OSDs
down_osds=$(ceph_exec ceph osd tree | grep -c "down" || true)
if [[ $down_osds -eq 0 ]]; then
    print_status "OK" "All OSDs are up"
else
    print_status "ERROR" "$down_osds OSDs are down"
    ceph_exec ceph osd tree | grep "down"
fi

# 3. Check placement group status
print_header "Placement Group Validation"

pg_stat=$(ceph_exec ceph pg stat)
print_status "INFO" "PG Status: $pg_stat"

# Check for unhealthy PGs
inactive_pgs=$(ceph_exec ceph pg ls | grep -v "active+clean" | wc -l)
if [[ $inactive_pgs -le 1 ]]; then  # Account for header line
    print_status "OK" "All placement groups are healthy (active+clean)"
else
    print_status "WARN" "$((inactive_pgs - 1)) placement groups are not in active+clean state"
    print_status "INFO" "Unhealthy PGs:"
    ceph_exec ceph pg ls | grep -v "active+clean" | head -10
fi

# 4. Check storage utilization and balance
print_header "Storage Utilization Validation"

print_status "INFO" "Storage overview:"
ceph_exec ceph df

# Check OSD usage balance
print_status "INFO" "OSD usage distribution:"
ceph_exec ceph osd df

# Calculate usage variance
echo
print_status "INFO" "Checking storage balance..."
osd_usage=$(ceph_exec ceph osd df | grep "^[0-9]" | awk '{print $6}' | sed 's/%//')
if [[ -n "$osd_usage" ]]; then
    min_usage=$(echo "$osd_usage" | sort -n | head -1)
    max_usage=$(echo "$osd_usage" | sort -n | tail -1)
    variance=$((max_usage - min_usage))
    
    if [[ $variance -le 10 ]]; then
        print_status "OK" "Storage is well balanced (max variance: ${variance}%)"
    elif [[ $variance -le 20 ]]; then
        print_status "WARN" "Storage balance is acceptable (max variance: ${variance}%)"
    else
        print_status "ERROR" "Storage is imbalanced (max variance: ${variance}%)"
    fi
fi

# 5. Check CRUSH map integrity
print_header "CRUSH Map Validation"

print_status "INFO" "CRUSH map structure:"
ceph_exec ceph osd crush tree

# Verify failure domains
print_status "INFO" "Checking failure domain configuration..."
crush_rules=$(ceph_exec ceph osd crush rule ls)
for rule in $crush_rules; do
    rule_info=$(ceph_exec ceph osd crush rule dump "$rule")
    if echo "$rule_info" | grep -q "host"; then
        print_status "OK" "CRUSH rule '$rule' uses host-level failure domain"
    else
        print_status "WARN" "CRUSH rule '$rule' may not have proper failure domain"
    fi
done

# 6. Check data replication
print_header "Data Replication Validation"

pools=$(ceph_exec ceph osd pool ls)
for pool in $pools; do
    size=$(ceph_exec ceph osd pool get "$pool" size | awk '{print $2}')
    min_size=$(ceph_exec ceph osd pool get "$pool" min_size | awk '{print $2}')
    print_status "INFO" "Pool '$pool': size=$size, min_size=$min_size"
    
    if [[ $size -eq 3 && $min_size -eq 2 ]]; then
        print_status "OK" "Pool '$pool' has proper replication settings"
    else
        print_status "WARN" "Pool '$pool' has non-standard replication settings"
    fi
done

# 7. Performance validation
print_header "Performance Validation"

print_status "INFO" "OSD performance metrics:"
ceph_exec ceph osd perf

# Check for slow operations
slow_ops=$(ceph_exec ceph status | grep "slow ops" || echo "")
if [[ -z "$slow_ops" ]]; then
    print_status "OK" "No slow operations detected"
else
    print_status "WARN" "Slow operations detected: $slow_ops"
fi

# 8. Kubernetes integration validation
print_header "Kubernetes Integration Validation"

# Check Rook operator status
operator_ready=$(kubectl get deployment -n $NAMESPACE rook-ceph-operator -o jsonpath='{.status.readyReplicas}')
operator_desired=$(kubectl get deployment -n $NAMESPACE rook-ceph-operator -o jsonpath='{.spec.replicas}')
if [[ $operator_ready -eq $operator_desired ]]; then
    print_status "OK" "Rook operator is running ($operator_ready/$operator_desired replicas)"
else
    print_status "WARN" "Rook operator not fully ready ($operator_ready/$operator_desired replicas)"
fi

# Check CSI drivers
rbd_provisioner=$(kubectl get pods -n $NAMESPACE -l app=csi-rbdplugin-provisioner | grep -c "Running" || echo "0")
if [[ $rbd_provisioner -gt 0 ]]; then
    print_status "OK" "RBD CSI provisioner is running"
else
    print_status "ERROR" "RBD CSI provisioner is not running"
fi

rbd_plugin=$(kubectl get daemonset -n $NAMESPACE csi-rbdplugin -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [[ $rbd_plugin -gt 0 ]]; then
    print_status "OK" "RBD CSI plugin is running on $rbd_plugin nodes"
else
    print_status "ERROR" "RBD CSI plugin is not running"
fi

# Check storage class
if kubectl get storageclass ceph-block &>/dev/null; then
    is_default=$(kubectl get storageclass ceph-block -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')
    if [[ "$is_default" == "true" ]]; then
        print_status "OK" "ceph-block storage class exists and is default"
    else
        print_status "WARN" "ceph-block storage class exists but is not default"
    fi
else
    print_status "ERROR" "ceph-block storage class not found"
fi

# 9. Functional testing
print_header "Functional Testing"

print_status "INFO" "Testing PVC creation and mounting..."

# Create test PVC
test_pvc_name="validation-test-pvc-$(date +%s)"
cat > /tmp/test-pvc.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $test_pvc_name
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: ceph-block
EOF

kubectl apply -f /tmp/test-pvc.yaml

# Wait for PVC to be bound
if kubectl wait --for=condition=bound pvc/$test_pvc_name -n default --timeout=300s; then
    print_status "OK" "Test PVC bound successfully"
    
    # Create test pod
    test_pod_name="validation-test-pod-$(date +%s)"
    cat > /tmp/test-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: $test_pod_name
  namespace: default
spec:
  containers:
  - name: test-container
    image: busybox
    command: ["/bin/sh"]
    args: ["-c", "echo 'OSD replacement validation test' > /mnt/test.txt && cat /mnt/test.txt && sleep 60"]
    volumeMounts:
    - name: test-volume
      mountPath: /mnt
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: $test_pvc_name
  restartPolicy: Never
EOF

    kubectl apply -f /tmp/test-pod.yaml
    
    if kubectl wait --for=condition=ready pod/$test_pod_name -n default --timeout=300s; then
        # Check if file was written
        sleep 5
        test_output=$(kubectl exec $test_pod_name -n default -- cat /mnt/test.txt 2>/dev/null || echo "FAILED")
        if [[ "$test_output" == "OSD replacement validation test" ]]; then
            print_status "OK" "Storage functionality test passed"
        else
            print_status "ERROR" "Storage functionality test failed"
        fi
    else
        print_status "ERROR" "Test pod failed to start"
    fi
    
    # Cleanup
    kubectl delete pod $test_pod_name -n default --ignore-not-found=true
else
    print_status "ERROR" "Test PVC failed to bind"
fi

kubectl delete pvc $test_pvc_name -n default --ignore-not-found=true
rm -f /tmp/test-pvc.yaml /tmp/test-pod.yaml

# 10. Final summary
print_header "Validation Summary"

# Collect final metrics
total_osds=$(ceph_exec ceph osd stat | awk '{print $1}')
healthy_osds=$(ceph_exec ceph osd tree | grep -c "up.*in" || echo "0")
total_storage=$(ceph_exec ceph df | grep "TOTAL" | awk '{print $2}')
used_storage=$(ceph_exec ceph df | grep "TOTAL" | awk '{print $3}')
usage_pct=$(ceph_exec ceph df | grep "TOTAL" | awk '{print $4}' | sed 's/%//')

print_status "INFO" "Final cluster state:"
echo "  - Total OSDs: $total_osds"
echo "  - Healthy OSDs: $healthy_osds"
echo "  - Total Storage: $total_storage"
echo "  - Used Storage: $used_storage ($usage_pct%)"
echo "  - Cluster Health: $health_status"

# Generate recommendations
echo
print_status "INFO" "Recommendations:"
if [[ $usage_pct -gt 80 ]]; then
    echo "  - Monitor storage usage closely (currently ${usage_pct}%)"
fi

if [[ $healthy_osds -lt $total_osds ]]; then
    echo "  - Investigate unhealthy OSDs"
fi

echo "  - Continue monitoring cluster health for 24-48 hours"
echo "  - Verify backup processes are working correctly"
echo "  - Document the successful OSD replacement"

# Check if validation passed
validation_passed=true

if ! echo "$health_status" | grep -q "HEALTH_OK"; then
    validation_passed=false
fi

if [[ $down_osds -gt 0 ]]; then
    validation_passed=false
fi

if [[ $inactive_pgs -gt 1 ]]; then
    validation_passed=false
fi

if [[ $validation_passed == true ]]; then
    print_status "OK" "OSD replacement validation PASSED"
    echo
    echo -e "${GREEN}✅ The OSD replacement was successful!${NC}"
    echo "The cluster is healthy and fully functional."
else
    print_status "ERROR" "OSD replacement validation FAILED"
    echo
    echo -e "${RED}❌ Issues detected after OSD replacement.${NC}"
    echo "Please review the validation results and address any problems."
    exit 1
fi

echo
print_status "INFO" "Validation completed at $(date)"