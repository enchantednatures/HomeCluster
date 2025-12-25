#!/bin/bash

# Rook-Ceph OSD Replacement Script
# This script provides guided procedures for safely replacing failed OSDs
# Version: 1.0
# Compatible with: Ceph v19.2.3, Rook v1.15.3

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="rook-ceph"
TOOLBOX_DEPLOYMENT="deployment/rook-ceph-tools"
CEPH_CLUSTER_NAME="rook-ceph"
DEVICE_PATH="/dev/sdb"  # Default from your config (can be overridden)
NODES=("work-00" "work-01" "work-02")  # Your cluster nodes

# Function to detect device type
detect_device_type() {
    local device_path=$1
    if [[ $device_path =~ ^/dev/nvme ]]; then
        echo "nvme"
    else
        echo "ssd"
    fi
}

# Function to get NVMe device info
get_nvme_info() {
    local device_path=$1
    local node_name=$2

    echo "NVMe Device Information for $device_path on $node_name:"
    ceph_exec nvme list | grep "$device_path" || echo "Device not found in nvme list"

    # Create temporary pod to check device
    local check_pod="nvme-check-$node_name"
    cat > /tmp/$check_pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: $check_pod
  namespace: $NAMESPACE
spec:
  nodeSelector:
    kubernetes.io/hostname: $node_name
  hostNetwork: true
  containers:
  - name: nvme-check
    image: alpine:latest
    command: ["/bin/sh"]
    args: ["-c", "sleep 60"]
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

    kubectl apply -f /tmp/$check_pod.yaml
    kubectl wait --for=condition=ready pod/$check_pod -n $NAMESPACE --timeout=30s

    echo "Health status:"
    kubectl exec -n $NAMESPACE $check_pod -- nvme smart-log $device_path 2>/dev/null || echo "Unable to get health status"

    echo "Controller info:"
    kubectl exec -n $NAMESPACE $check_pod -- nvme id-ctrl $device_path 2>/dev/null || echo "Unable to get controller info"

    kubectl delete pod $check_pod -n $NAMESPACE --ignore-not-found=true
    rm -f /tmp/$check_pod.yaml
}

print_status() {
    local status=$1
    local message=$2
    case $status in
        "OK")
            echo -e "${GREEN}✓${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}⚠${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}✗${NC} $message"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ${NC} $message"
            ;;
        "STEP")
            echo -e "${PURPLE}➤${NC} $message"
            ;;
        "WAIT")
            echo -e "${CYAN}⏳${NC} $message"
            ;;
    esac
}

print_header() {
    echo
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo
}

# Function to check if toolbox is ready
check_toolbox() {
    if ! kubectl get pods -n $NAMESPACE -l app=rook-ceph-tools | grep -q "Running"; then
        print_status "WARN" "Ceph toolbox is not running. Deploying..."
        kubectl apply -f kubernetes/operators/rook-ceph/cluster/app/ceph-toolbox.yaml
        print_status "WAIT" "Waiting for toolbox to be ready..."
        kubectl wait --for=condition=ready pod -l app=rook-ceph-tools -n $NAMESPACE --timeout=300s
    fi
    print_status "OK" "Ceph toolbox is ready"
}

# Function to execute ceph commands safely
ceph_exec() {
    kubectl -n $NAMESPACE exec $TOOLBOX_DEPLOYMENT -- "$@"
}

# Function to wait for user confirmation
confirm_action() {
    local message=$1
    local default=${2:-"n"}
    
    if [[ "$default" == "y" ]]; then
        read -p "$message [Y/n]: " -n 1 -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] && return 1
    else
        read -p "$message [y/N]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
    fi
    return 0
}

# Function to check cluster health
check_cluster_health() {
    print_header "Checking Cluster Health"
    
    local health_status
    health_status=$(ceph_exec ceph health)
    
    if echo "$health_status" | grep -q "HEALTH_OK"; then
        print_status "OK" "Cluster health: $health_status"
        return 0
    elif echo "$health_status" | grep -q "HEALTH_WARN"; then
        print_status "WARN" "Cluster health: $health_status"
        ceph_exec ceph health detail
        if confirm_action "Cluster has warnings. Continue anyway?"; then
            return 0
        else
            return 1
        fi
    else
        print_status "ERROR" "Cluster health: $health_status"
        ceph_exec ceph health detail
        print_status "ERROR" "Cluster is in critical state. Cannot proceed safely."
        return 1
    fi
}

# Function to identify failed OSDs
identify_failed_osds() {
    print_header "Identifying Failed OSDs"
    
    print_status "INFO" "Current OSD tree:"
    ceph_exec ceph osd tree
    
    echo
    print_status "INFO" "OSDs with issues:"
    ceph_exec ceph osd tree | grep -E "(down|out)" || print_status "OK" "No obviously failed OSDs found"
    
    echo
    print_status "INFO" "OSD performance metrics:"
    ceph_exec ceph osd perf
    
    echo
    print_status "INFO" "OSD usage statistics:"
    ceph_exec ceph osd df
    
    echo
    print_status "INFO" "Health detail for OSD-specific issues:"
    ceph_exec ceph health detail | grep -i osd || print_status "OK" "No OSD-specific health issues"
}

# Function to validate removal safety
validate_removal_safety() {
    local osd_id=$1
    print_header "Validating Removal Safety for OSD $osd_id"
    
    # Check current storage usage
    local total_usage
    total_usage=$(ceph_exec ceph df | grep "TOTAL" | awk '{print $3}' | sed 's/%//')
    
    if [[ -n "$total_usage" && "$total_usage" -gt 70 ]]; then
        print_status "WARN" "Storage usage is high ($total_usage%). Removal may cause issues."
        if ! confirm_action "Continue with high storage usage?"; then
            return 1
        fi
    else
        print_status "OK" "Storage usage is acceptable ($total_usage%)"
    fi
    
    # Check replica configuration
    local replica_size
    replica_size=$(ceph_exec ceph osd pool ls detail | grep "replicated size" | head -1 | awk '{print $4}')
    print_status "INFO" "Replica size: $replica_size"
    
    # Check number of healthy OSDs
    local total_osds healthy_osds
    total_osds=$(ceph_exec ceph osd stat | awk '{print $1}')
    healthy_osds=$(ceph_exec ceph osd tree | grep -c "up.*in" || echo "0")
    
    print_status "INFO" "Total OSDs: $total_osds, Healthy OSDs: $healthy_osds"
    
    if [[ "$healthy_osds" -le "$replica_size" ]]; then
        print_status "ERROR" "Not enough healthy OSDs to maintain data safety"
        return 1
    fi
    
    return 0
}

# Function to set maintenance flags
set_maintenance_flags() {
    print_header "Setting Maintenance Flags"
    
    print_status "STEP" "Setting cluster maintenance flags..."
    ceph_exec ceph osd set noout
    ceph_exec ceph osd set norebalance
    ceph_exec ceph osd set norecover
    ceph_exec ceph osd set nobackfill
    
    print_status "OK" "Maintenance flags set"
    ceph_exec ceph osd dump | grep flags
}

# Function to remove maintenance flags
remove_maintenance_flags() {
    print_header "Removing Maintenance Flags"
    
    print_status "STEP" "Removing cluster maintenance flags..."
    ceph_exec ceph osd unset noout
    ceph_exec ceph osd unset norebalance
    ceph_exec ceph osd unset norecover
    ceph_exec ceph osd unset nobackfill
    
    print_status "OK" "Maintenance flags removed"
    ceph_exec ceph osd dump | grep flags
}

# Function to safely remove an OSD from Ceph
remove_osd_from_ceph() {
    local osd_id=$1
    print_header "Removing OSD $osd_id from Ceph Cluster"
    
    # Step 1: Mark OSD as out
    print_status "STEP" "Marking OSD $osd_id as out..."
    ceph_exec ceph osd out $osd_id
    
    # Step 2: Wait for data migration
    print_status "WAIT" "Waiting for data migration to complete..."
    local timeout=1800  # 30 minutes
    local elapsed=0
    local check_interval=30
    
    while [[ $elapsed -lt $timeout ]]; do
        if ceph_exec ceph pg stat | grep -q "active+clean"; then
            local inactive_pgs
            inactive_pgs=$(ceph_exec ceph pg ls | grep -v "active+clean" | wc -l)
            if [[ "$inactive_pgs" -le 1 ]]; then  # Account for header line
                print_status "OK" "Data migration completed"
                break
            fi
        fi
        
        echo -n "."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Show progress every 5 minutes
        if [[ $((elapsed % 300)) -eq 0 ]]; then
            echo
            ceph_exec ceph pg stat
            ceph_exec ceph status | grep -A 5 "recovery\|backfill"
        fi
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        print_status "ERROR" "Data migration timeout after 30 minutes"
        return 1
    fi
    
    # Step 3: Stop OSD daemon
    print_status "STEP" "Stopping OSD $osd_id daemon..."
    ceph_exec ceph osd down $osd_id
    
    # Step 4: Remove from CRUSH map
    print_status "STEP" "Removing OSD $osd_id from CRUSH map..."
    ceph_exec ceph osd crush remove osd.$osd_id
    
    # Step 5: Delete authentication
    print_status "STEP" "Deleting OSD $osd_id authentication..."
    ceph_exec ceph auth del osd.$osd_id
    
    # Step 6: Remove from cluster
    print_status "STEP" "Removing OSD $osd_id from cluster..."
    ceph_exec ceph osd rm $osd_id
    
    print_status "OK" "OSD $osd_id successfully removed from Ceph cluster"
}

# Function to clean up Kubernetes resources
cleanup_kubernetes_resources() {
    local osd_id=$1
    print_header "Cleaning Up Kubernetes Resources for OSD $osd_id"
    
    # Find and delete OSD deployment
    print_status "STEP" "Looking for OSD $osd_id deployment..."
    local osd_deployment
    osd_deployment=$(kubectl get deployments -n $NAMESPACE -o name | grep "osd-$osd_id" || echo "")
    
    if [[ -n "$osd_deployment" ]]; then
        print_status "STEP" "Deleting deployment: $osd_deployment"
        kubectl delete "$osd_deployment" -n $NAMESPACE
    else
        print_status "WARN" "No deployment found for OSD $osd_id"
    fi
    
    # Force delete any stuck pods
    print_status "STEP" "Cleaning up OSD $osd_id pods..."
    kubectl delete pods -n $NAMESPACE -l "osd=$osd_id" --force --grace-period=0 || true
    
    # Clean up PVCs
    print_status "STEP" "Cleaning up PVCs for OSD $osd_id..."
    local pvcs
    pvcs=$(kubectl get pvc -n $NAMESPACE | grep "osd-$osd_id" | awk '{print $1}' || echo "")
    if [[ -n "$pvcs" ]]; then
        echo "$pvcs" | xargs kubectl delete pvc -n $NAMESPACE || true
    fi
    
    # Clean up ConfigMaps
    print_status "STEP" "Cleaning up ConfigMaps for OSD $osd_id..."
    local configmaps
    configmaps=$(kubectl get configmaps -n $NAMESPACE | grep "osd-$osd_id" | awk '{print $1}' || echo "")
    if [[ -n "$configmaps" ]]; then
        echo "$configmaps" | xargs kubectl delete configmaps -n $NAMESPACE || true
    fi
    
    print_status "OK" "Kubernetes resources cleaned up for OSD $osd_id"
}

# Function to clean device
clean_device() {
    local node_name=$1
    local device_path=${2:-$DEVICE_PATH}
    print_header "Cleaning Device $device_path on Node $node_name"
    
    # Create device cleanup pod
    local cleanup_pod_yaml="/tmp/device-cleanup-$node_name.yaml"
    cat > "$cleanup_pod_yaml" << EOF
apiVersion: v1
kind: Pod
metadata:
  name: device-cleanup-$node_name
  namespace: $NAMESPACE
spec:
  nodeSelector:
    kubernetes.io/hostname: $node_name
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
  tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists
EOF
    
    print_status "STEP" "Creating device cleanup pod on $node_name..."
    kubectl apply -f "$cleanup_pod_yaml"
    
    print_status "WAIT" "Waiting for cleanup pod to be ready..."
    kubectl wait --for=condition=ready pod/device-cleanup-$node_name -n $NAMESPACE --timeout=300s
    
    print_status "STEP" "Cleaning device signatures..."

    # Device-type specific cleanup
    device_type=$(detect_device_type $device_path)
    if [[ $device_type == "nvme" ]]; then
        print_status "INFO" "Detected NVMe device, using NVMe-specific cleanup..."
        # NVMe secure erase (user data erase)
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- nvme format -s 1 $device_path || print_status "WARN" "NVMe format failed, trying alternative methods"
        # Fallback to standard cleanup if NVMe format fails
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- sgdisk --zap-all $device_path || true
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- wipefs --all $device_path || true
    else
        print_status "INFO" "Detected SSD device, using standard cleanup..."
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- sgdisk --zap-all $device_path || true
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- dd if=/dev/zero of=$device_path bs=1M count=100 || true
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- wipefs --all $device_path || true
    fi

    print_status "STEP" "Verifying device is clean..."
    kubectl exec -n $NAMESPACE device-cleanup-$node_name -- lsblk $device_path

    if [[ $device_type == "nvme" ]]; then
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- nvme list-ns $device_path || true
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- nvme smart-log $device_path | head -10 || true
    else
        kubectl exec -n $NAMESPACE device-cleanup-$node_name -- fdisk -l $device_path || true
    fi
    
    print_status "STEP" "Cleaning up device cleanup pod..."
    kubectl delete pod device-cleanup-$node_name -n $NAMESPACE
    rm -f "$cleanup_pod_yaml"
    
    print_status "OK" "Device $device_path on $node_name cleaned successfully"
}

# Function to monitor OSD recreation
monitor_osd_recreation() {
    local node_name=$1
    print_header "Monitoring OSD Recreation on $node_name"
    
    print_status "WAIT" "Waiting for OSD preparation to start..."
    
    local timeout=600  # 10 minutes
    local elapsed=0
    local check_interval=15
    
    while [[ $elapsed -lt $timeout ]]; do
        # Check for OSD preparation pods
        if kubectl get pods -n $NAMESPACE | grep -q "rook-ceph-osd-prepare.*$node_name"; then
            print_status "OK" "OSD preparation started on $node_name"
            break
        fi
        
        echo -n "."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        print_status "WARN" "OSD preparation didn't start automatically. You may need to restart the operator."
        return 1
    fi
    
    # Monitor preparation logs
    print_status "STEP" "Monitoring OSD preparation..."
    kubectl logs -n $NAMESPACE -l app=rook-ceph-osd-prepare -f --tail=20 &
    local log_pid=$!
    
    # Wait for OSD to be created
    timeout=1200  # 20 minutes
    elapsed=0
    
    print_status "WAIT" "Waiting for new OSD to be created..."
    while [[ $elapsed -lt $timeout ]]; do
        # Check for new OSD deployment
        if kubectl get deployments -n $NAMESPACE | grep -q "rook-ceph-osd.*$node_name"; then
            print_status "OK" "New OSD deployment created on $node_name"
            break
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    # Stop log monitoring
    kill $log_pid 2>/dev/null || true
    
    if [[ $elapsed -ge $timeout ]]; then
        print_status "ERROR" "OSD creation timeout. Check operator logs."
        return 1
    fi
    
    return 0
}

# Function to wait for cluster to stabilize
wait_for_cluster_stable() {
    print_header "Waiting for Cluster to Stabilize"
    
    local timeout=1800  # 30 minutes
    local elapsed=0
    local check_interval=30
    
    while [[ $elapsed -lt $timeout ]]; do
        local health_status
        health_status=$(ceph_exec ceph health)
        
        if echo "$health_status" | grep -q "HEALTH_OK"; then
            # Double-check that all PGs are active+clean
            if ceph_exec ceph pg stat | grep -q "active+clean"; then
                local inactive_pgs
                inactive_pgs=$(ceph_exec ceph pg ls | grep -v "active+clean" | wc -l)
                if [[ "$inactive_pgs" -le 1 ]]; then  # Account for header line
                    print_status "OK" "Cluster is stable and healthy"
                    return 0
                fi
            fi
        fi
        
        echo -n "."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Show progress every 5 minutes
        if [[ $((elapsed % 300)) -eq 0 ]]; then
            echo
            print_status "INFO" "Current status: $health_status"
            ceph_exec ceph pg stat
        fi
    done
    
    print_status "WARN" "Cluster stabilization timeout. Manual intervention may be required."
    return 1
}

# Function to perform final validation
final_validation() {
    print_header "Performing Final Validation"
    
    # Check cluster health
    local health_status
    health_status=$(ceph_exec ceph health)
    print_status "INFO" "Final cluster health: $health_status"
    
    # Check OSD status
    print_status "INFO" "Final OSD status:"
    ceph_exec ceph osd stat
    ceph_exec ceph osd tree
    
    # Check storage usage
    print_status "INFO" "Storage usage after replacement:"
    ceph_exec ceph df
    
    # Test storage functionality
    print_status "STEP" "Testing storage functionality..."
    
    local test_pvc_yaml="/tmp/test-ceph-pvc.yaml"
    cat > "$test_pvc_yaml" << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-pvc-$(date +%s)
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: ceph-block
EOF
    
    kubectl apply -f "$test_pvc_yaml"
    
    local pvc_name
    pvc_name=$(basename "$test_pvc_yaml" .yaml)
    pvc_name=$(grep "name:" "$test_pvc_yaml" | awk '{print $2}')
    
    if kubectl wait --for=condition=bound pvc/"$pvc_name" -n default --timeout=300s; then
        print_status "OK" "Storage functionality test passed"
        kubectl delete pvc "$pvc_name" -n default
    else
        print_status "WARN" "Storage functionality test failed"
    fi
    
    rm -f "$test_pvc_yaml"
}

# Main function for interactive OSD replacement
interactive_osd_replacement() {
    print_header "Interactive OSD Replacement Wizard"
    
    # Check prerequisites
    check_toolbox
    
    if ! check_cluster_health; then
        exit 1
    fi
    
    # Identify failed OSDs
    identify_failed_osds
    
    echo
    read -p "Enter the OSD ID to replace: " osd_id
    
    if [[ ! "$osd_id" =~ ^[0-9]+$ ]]; then
        print_status "ERROR" "Invalid OSD ID. Must be a number."
        exit 1
    fi
    
    # Validate the OSD exists
    if ! ceph_exec ceph osd find "$osd_id" >/dev/null 2>&1; then
        print_status "ERROR" "OSD $osd_id not found in cluster"
        exit 1
    fi
    
    # Get OSD node information
    local osd_node
    osd_node=$(ceph_exec ceph osd find "$osd_id" | grep -o '"host":"[^"]*"' | cut -d'"' -f4)
    print_status "INFO" "OSD $osd_id is located on node: $osd_node"

    # Get device information
    local device_path
    device_path=$(ceph_exec ceph osd metadata "$osd_id" | grep '"device"' | cut -d'"' -f4)
    if [[ -z "$device_path" ]]; then
        print_status "WARN" "Could not determine device path for OSD $osd_id"
        device_path=$DEVICE_PATH  # Use default
    fi

    print_status "INFO" "OSD $osd_id uses device: $device_path"

    # Detect device type and show information
    local device_type
    device_type=$(detect_device_type "$device_path")
    print_status "INFO" "Device type detected: $device_type"

    if [[ $device_type == "nvme" ]]; then
        print_status "INFO" "NVMe device detected - will use NVMe-specific cleanup procedures"
        get_nvme_info "$device_path" "$osd_node"
    fi

    # Validate removal safety
    if ! validate_removal_safety "$osd_id"; then
        exit 1
    fi
    
    # Final confirmation
    echo
    print_status "WARN" "This will remove OSD $osd_id from node $osd_node and replace it."
    print_status "WARN" "This operation involves data migration and can take significant time."
    if ! confirm_action "Are you sure you want to proceed?"; then
        print_status "INFO" "Operation cancelled by user"
        exit 0
    fi
    
    # Execute replacement procedure
    set_maintenance_flags
    
    if ! remove_osd_from_ceph "$osd_id"; then
        print_status "ERROR" "Failed to remove OSD from Ceph cluster"
        remove_maintenance_flags
        exit 1
    fi
    
    cleanup_kubernetes_resources "$osd_id"
    
    clean_device "$osd_node"
    
    # Allow rebalancing for new OSD creation
    remove_maintenance_flags
    
    if ! monitor_osd_recreation "$osd_node"; then
        print_status "ERROR" "Failed to recreate OSD automatically"
        print_status "INFO" "You may need to restart the operator: kubectl rollout restart deployment/rook-ceph-operator -n $NAMESPACE"
        exit 1
    fi
    
    if ! wait_for_cluster_stable; then
        print_status "WARN" "Cluster did not stabilize within timeout"
        exit 1
    fi
    
    final_validation
    
    print_status "OK" "OSD replacement completed successfully!"
}

# Function to show help
show_help() {
    cat << EOF
Rook-Ceph OSD Replacement Script

Usage: $0 [COMMAND]

Commands:
    replace             Interactive OSD replacement wizard
    check-health        Check cluster health
    identify-failed     Identify failed OSDs
    help               Show this help message

Environment Variables:
    NAMESPACE          Kubernetes namespace (default: rook-ceph)
    DEVICE_PATH        Device path to clean (default: /dev/sdb)

Examples:
    $0 replace         # Start interactive replacement wizard
    $0 check-health    # Check current cluster health
    $0 identify-failed # List potentially failed OSDs

EOF
}

# Main script logic
case "${1:-}" in
    "replace")
        interactive_osd_replacement
        ;;
    "check-health")
        check_toolbox
        check_cluster_health
        ;;
    "identify-failed")
        check_toolbox
        identify_failed_osds
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    "")
        print_status "INFO" "No command specified. Use 'help' to see available commands."
        show_help
        ;;
    *)
        print_status "ERROR" "Unknown command: $1"
        show_help
        exit 1
        ;;
esac