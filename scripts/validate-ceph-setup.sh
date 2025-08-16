#!/bin/bash

# Rook-Ceph Validation Script for HomeCluster
# This script validates the Ceph cluster configuration and deployment

set -e

echo "🔍 Validating Rook-Ceph Setup for HomeCluster..."
echo "=================================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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
    esac
}

# Check if kubectl is available and cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    print_status "ERROR" "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

print_status "OK" "Kubernetes cluster connection verified"

# Check if rook-ceph namespace exists
if kubectl get namespace rook-ceph &>/dev/null; then
    print_status "OK" "rook-ceph namespace exists"
else
    print_status "ERROR" "rook-ceph namespace not found"
    exit 1
fi

# Check if Flux is managing the deployment
echo -e "\n${BLUE}📋 Flux GitOps Status${NC}"
echo "========================"

if kubectl get kustomization -n flux-system rook-ceph-operator &>/dev/null; then
    operator_status=$(kubectl get kustomization -n flux-system rook-ceph-operator -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$operator_status" = "True" ]; then
        print_status "OK" "Rook-Ceph operator Flux Kustomization is ready"
    else
        print_status "WARN" "Rook-Ceph operator Flux Kustomization is not ready"
    fi
else
    print_status "ERROR" "Rook-Ceph operator Flux Kustomization not found"
fi

if kubectl get kustomization -n flux-system rook-ceph-cluster &>/dev/null; then
    cluster_status=$(kubectl get kustomization -n flux-system rook-ceph-cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$cluster_status" = "True" ]; then
        print_status "OK" "Rook-Ceph cluster Flux Kustomization is ready"
    else
        print_status "WARN" "Rook-Ceph cluster Flux Kustomization is not ready"
    fi
else
    print_status "ERROR" "Rook-Ceph cluster Flux Kustomization not found"
fi

# Check operator deployment
echo -e "\n${BLUE}🚀 Operator Status${NC}"
echo "==================="

if kubectl get deployment -n rook-ceph rook-ceph-operator &>/dev/null; then
    ready_replicas=$(kubectl get deployment -n rook-ceph rook-ceph-operator -o jsonpath='{.status.readyReplicas}')
    desired_replicas=$(kubectl get deployment -n rook-ceph rook-ceph-operator -o jsonpath='{.spec.replicas}')
    if [ "$ready_replicas" = "$desired_replicas" ] && [ "$ready_replicas" != "" ]; then
        print_status "OK" "Rook-Ceph operator is running ($ready_replicas/$desired_replicas replicas)"
    else
        print_status "WARN" "Rook-Ceph operator not fully ready ($ready_replicas/$desired_replicas replicas)"
    fi
else
    print_status "ERROR" "Rook-Ceph operator deployment not found"
fi

# Check if CephCluster exists and status
echo -e "\n${BLUE}💾 Ceph Cluster Status${NC}"
echo "======================"

if kubectl get cephcluster -n rook-ceph rook-ceph &>/dev/null; then
    ceph_phase=$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.phase}')
    ceph_state=$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.state}')

    print_status "INFO" "CephCluster exists with phase: $ceph_phase, state: $ceph_state"

    if [ "$ceph_phase" = "Ready" ] && [ "$ceph_state" = "Created" ]; then
        print_status "OK" "CephCluster is healthy and ready"
    else
        print_status "WARN" "CephCluster is not in optimal state"
    fi
else
    print_status "ERROR" "CephCluster 'rook-ceph' not found"
fi

# Check storage classes
echo -e "\n${BLUE}💽 Storage Classes${NC}"
echo "=================="

if kubectl get storageclass ceph-block &>/dev/null; then
    is_default=$(kubectl get storageclass ceph-block -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')
    if [ "$is_default" = "true" ]; then
        print_status "OK" "ceph-block storage class exists and is set as default"
    else
        print_status "WARN" "ceph-block storage class exists but is not default"
    fi
else
    print_status "ERROR" "ceph-block storage class not found"
fi

if kubectl get storageclass ceph-bucket &>/dev/null; then
    print_status "OK" "ceph-bucket storage class exists"
else
    print_status "WARN" "ceph-bucket storage class not found"
fi

# Check worker nodes and storage
echo -e "\n${BLUE}🖥️  Node and Storage Validation${NC}"
echo "=================================="

worker_nodes=$(kubectl get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
if [ "$worker_nodes" -ge 3 ]; then
    print_status "OK" "Found $worker_nodes worker nodes (minimum 3 required for HA)"
else
    print_status "WARN" "Only $worker_nodes worker nodes found (minimum 3 recommended for HA)"
fi

# List worker nodes for reference
echo -e "\n${BLUE}Worker Nodes:${NC}"
kubectl get nodes -l node-role.kubernetes.io/worker -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[4].type,AGE:.metadata.creationTimestamp

# Check for OSDs if cluster is ready
if kubectl get deployment -n rook-ceph | grep -q rook-ceph-osd; then
    osd_count=$(kubectl get deployment -n rook-ceph | grep rook-ceph-osd | wc -l)
    print_status "INFO" "Found $osd_count OSD deployments"

    # Check OSD pod status
    osd_ready=0
    for osd in $(kubectl get pods -n rook-ceph -l app=rook-ceph-osd --no-headers | awk '{print $1}'); do
        if kubectl get pod -n rook-ceph "$osd" -o jsonpath='{.status.phase}' | grep -q "Running"; then
            ((osd_ready++))
        fi
    done

    if [ "$osd_ready" -eq "$osd_count" ]; then
        print_status "OK" "All $osd_ready OSD pods are running"
    else
        print_status "WARN" "Only $osd_ready out of $osd_count OSD pods are running"
    fi
else
    print_status "INFO" "No OSD deployments found (cluster may still be initializing)"
fi

# Check MON status
mon_count=$(kubectl get pods -n rook-ceph -l app=rook-ceph-mon --no-headers | wc -l)
if [ "$mon_count" -ge 3 ]; then
    print_status "OK" "Found $mon_count MON pods (quorum possible)"
else
    print_status "WARN" "Only $mon_count MON pods found (3 required for quorum)"
fi

# Check if object store is configured
echo -e "\n${BLUE}🪣 Object Store Status${NC}"
echo "======================"

if kubectl get cephobjectstore -n rook-ceph ceph-objectstore &>/dev/null; then
    rgw_phase=$(kubectl get cephobjectstore -n rook-ceph ceph-objectstore -o jsonpath='{.status.phase}')
    if [ "$rgw_phase" = "Ready" ]; then
        print_status "OK" "CephObjectStore is ready"
    else
        print_status "WARN" "CephObjectStore phase: $rgw_phase"
    fi
else
    print_status "INFO" "CephObjectStore not found (may not be deployed yet)"
fi

# Check RGW pods
rgw_pods=$(kubectl get pods -n rook-ceph -l app=rook-ceph-rgw --no-headers 2>/dev/null | wc -l)
if [ "$rgw_pods" -gt 0 ]; then
    print_status "OK" "Found $rgw_pods RGW pods"
else
    print_status "INFO" "No RGW pods found (object store may not be deployed)"
fi

# Final recommendations
echo -e "\n${BLUE}📝 Recommendations${NC}"
echo "=================="

echo "1. Verify your actual node names and device paths in ceph-cluster.yaml"
echo "2. Check that storage devices are clean (no existing filesystems)"
echo "3. Monitor the deployment with: kubectl get pods -n rook-ceph -w"
echo "4. Once ready, test with: kubectl apply -f sample-bucket-claim.yaml"

# Configuration check
echo -e "\n${BLUE}⚙️  Configuration Validation${NC}"
echo "============================="

if grep -q "talos-worker-1" /home/hcasten/dev/HomeCluster/kubernetes/operators/rook-ceph/cluster/ceph-cluster.yaml 2>/dev/null; then
    print_status "WARN" "Default node names found in ceph-cluster.yaml - please update with actual node names"
else
    print_status "OK" "Node names appear to be customized in ceph-cluster.yaml"
fi

if grep -q "/dev/sdb" /home/hcasten/dev/HomeCluster/kubernetes/operators/rook-ceph/cluster/ceph-cluster.yaml 2>/dev/null; then
    print_status "WARN" "Default device paths found in ceph-cluster.yaml - please verify these match your setup"
else
    print_status "OK" "Device paths appear to be customized in ceph-cluster.yaml"
fi

# Check for recent improvements
echo -e "\n${BLUE}🔧 Recent Enhancements Check${NC}"
echo "============================="

if kubectl get prometheusrule -n rook-ceph rook-ceph-alerts &>/dev/null; then
    print_status "OK" "Prometheus alerts configured"
else
    print_status "WARN" "Prometheus alerts not found - consider adding monitoring rules"
fi

if kubectl get volumesnapshotclass ceph-block-snapshot &>/dev/null; then
    print_status "OK" "Volume snapshot support configured"
else
    print_status "WARN" "Volume snapshot support not configured"
fi

if kubectl get storageclass ceph-block-retain &>/dev/null; then
    print_status "OK" "Retain storage class available"
else
    print_status "WARN" "Consider adding ceph-block-retain storage class for critical data"
fi

# Check encryption status
echo -e "\n${BLUE}🔒 Security Configuration${NC}"
echo "=========================="

if kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.spec.network.connections.encryption.enabled}' | grep -q "true"; then
    print_status "OK" "Cluster encryption enabled"
else
    print_status "WARN" "Cluster encryption disabled - consider enabling for security"
fi

echo -e "\n${GREEN}✅ Validation complete!${NC}"
echo "======================================"
echo "For detailed troubleshooting, check:"
echo "  - kubectl logs -n rook-ceph deployment/rook-ceph-operator"
echo "  - kubectl -n rook-ceph get cephcluster rook-ceph -o yaml"
echo "  - kubectl get events -n rook-ceph --sort-by='.lastTimestamp'"
