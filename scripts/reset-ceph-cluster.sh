#!/bin/bash

# Rook-Ceph Cluster Reset Script
# This script safely resets the Ceph cluster to fix initialization issues

set -e

echo "🔄 Resetting Rook-Ceph Cluster..."
echo "=================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check if kubectl is available
if ! kubectl cluster-info &>/dev/null; then
    print_status "ERROR" "Cannot connect to Kubernetes cluster"
    exit 1
fi

print_status "INFO" "Starting Ceph cluster reset procedure"

# Step 1: Delete the CephCluster (but keep operator)
print_status "INFO" "Removing CephCluster resource..."
kubectl delete cephcluster -n rook-ceph rook-ceph --ignore-not-found=true

# Step 2: Wait for cleanup
print_status "INFO" "Waiting for Ceph cluster cleanup (60 seconds)..."
sleep 60

# Step 3: Delete stuck OSD jobs and pods
print_status "INFO" "Cleaning up stuck OSD resources..."
kubectl delete jobs -n rook-ceph --all --ignore-not-found=true
kubectl delete pods -n rook-ceph -l app=rook-ceph-osd --ignore-not-found=true --force
kubectl delete pods -n rook-ceph -l app=rook-ceph-osd-prepare --ignore-not-found=true --force

# Step 4: Clean up CSI resources
print_status "INFO" "Cleaning up CSI resources..."
kubectl delete pods -n rook-ceph -l app=csi-rbdplugin-provisioner --ignore-not-found=true --force
kubectl delete pods -n rook-ceph -l app=csi-cephfsplugin-provisioner --ignore-not-found=true --force

# Step 5: Remove finalizers from any stuck resources
print_status "INFO" "Removing finalizers from stuck resources..."
for resource in $(kubectl get cephcluster,cephobjectstore,cephblockpool -n rook-ceph -o name 2>/dev/null || true); do
    kubectl patch $resource -n rook-ceph -p '{"metadata":{"finalizers":[]}}' --type=merge || true
done

# Step 6: Clean device signatures on nodes (this needs to be done on each node)
print_status "WARN" "IMPORTANT: You need to clean device signatures on each node manually:"
echo "Run this on each worker node (work-00, work-01, work-02):"
echo "  sudo sgdisk --zap-all /dev/sdb"
echo "  sudo dd if=/dev/zero of=/dev/sdb bs=1M count=100"
echo "  sudo wipefs --all /dev/sdb"

# Step 7: Wait for user confirmation
read -p "Have you cleaned the device signatures on all nodes? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_status "ERROR" "Please clean device signatures first, then run this script again"
    exit 1
fi

print_status "OK" "Reset procedure completed"
print_status "INFO" "You can now apply the updated Ceph cluster configuration"
print_status "INFO" "Run: kubectl apply -f kubernetes/operators/rook-ceph/cluster/"
