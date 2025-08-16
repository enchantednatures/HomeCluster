#!/bin/bash

# Comprehensive Ceph Health Check Script
# This script performs detailed health checks on the Rook-Ceph cluster

set -e

echo "🔍 Comprehensive Ceph Health Check"
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

print_status "INFO" "Starting comprehensive health check at $(date)"

# 1. Check Ceph cluster health
echo -e "\n${BLUE}🏥 Ceph Cluster Health${NC}"
echo "======================="

if kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph status >/dev/null 2>&1; then
    ceph_health=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph health)

    if echo "$ceph_health" | grep -q "HEALTH_OK"; then
        print_status "OK" "Ceph cluster health: $ceph_health"
    elif echo "$ceph_health" | grep -q "HEALTH_WARN"; then
        print_status "WARN" "Ceph cluster health: $ceph_health"
        # Show detailed health information
        kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph health detail
    else
        print_status "ERROR" "Ceph cluster health: $ceph_health"
        kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph health detail
    fi
else
    print_status "ERROR" "Cannot connect to Ceph cluster via toolbox"
fi

# 2. Check OSD status
echo -e "\n${BLUE}💾 OSD Status${NC}"
echo "=============="

if kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd stat >/dev/null 2>&1; then
    osd_stat=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd stat)
    print_status "INFO" "OSD Status: $osd_stat"

    # Check for down OSDs
    down_osds=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd tree | grep -c "down" || true)
    if [ "$down_osds" -eq 0 ]; then
        print_status "OK" "All OSDs are up"
    else
        print_status "WARN" "$down_osds OSDs are down"
        kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd tree | grep "down"
    fi
else
    print_status "ERROR" "Cannot retrieve OSD status"
fi

# 3. Check storage utilization
echo -e "\n${BLUE}📊 Storage Utilization${NC}"
echo "======================="

if kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph df >/dev/null 2>&1; then
    storage_info=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph df)
    echo "$storage_info"

    # Extract usage percentage
    usage_pct=$(echo "$storage_info" | grep "TOTAL" | awk '{print $4}' | sed 's/%//')
    if [ -n "$usage_pct" ] && [ "$usage_pct" -lt 80 ]; then
        print_status "OK" "Storage usage is healthy ($usage_pct%)"
    elif [ -n "$usage_pct" ] && [ "$usage_pct" -lt 90 ]; then
        print_status "WARN" "Storage usage is high ($usage_pct%)"
    elif [ -n "$usage_pct" ]; then
        print_status "ERROR" "Storage usage is critical ($usage_pct%)"
    fi
else
    print_status "ERROR" "Cannot retrieve storage utilization"
fi

# 4. Check placement group status
echo -e "\n${BLUE}🔗 Placement Group Status${NC}"
echo "=========================="

if kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph pg stat >/dev/null 2>&1; then
    pg_stat=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph pg stat)
    print_status "INFO" "PG Status: $pg_stat"

    # Check for unhealthy PGs
    if echo "$pg_stat" | grep -q "active+clean"; then
        unhealthy_pgs=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph pg ls | grep -v "active+clean" | wc -l || true)
        if [ "$unhealthy_pgs" -eq 1 ]; then  # Header line
            print_status "OK" "All placement groups are healthy"
        else
            print_status "WARN" "$((unhealthy_pgs - 1)) placement groups are not in active+clean state"
            kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph pg ls | grep -v "active+clean" | head -10
        fi
    fi
else
    print_status "ERROR" "Cannot retrieve placement group status"
fi

# 5. Check monitor quorum
echo -e "\n${BLUE}👥 Monitor Quorum${NC}"
echo "=================="

if kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph mon stat >/dev/null 2>&1; then
    mon_stat=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph mon stat)
    print_status "INFO" "Monitor Status: $mon_stat"

    # Check quorum size
    quorum_size=$(echo "$mon_stat" | grep -o "quorum [0-9]*" | awk '{print $2}')
    if [ -n "$quorum_size" ] && [ "$quorum_size" -ge 2 ]; then
        print_status "OK" "Monitor quorum is healthy ($quorum_size monitors)"
    else
        print_status "WARN" "Monitor quorum may be insufficient ($quorum_size monitors)"
    fi
else
    print_status "ERROR" "Cannot retrieve monitor status"
fi

# 6. Check manager status
echo -e "\n${BLUE}🎛️  Manager Status${NC}"
echo "=================="

mgr_pods=$(kubectl -n rook-ceph get pods -l app=rook-ceph-mgr --no-headers | wc -l)
mgr_ready=$(kubectl -n rook-ceph get pods -l app=rook-ceph-mgr --no-headers | grep "Running" | wc -l)

if [ "$mgr_ready" -gt 0 ]; then
    print_status "OK" "Manager pods running: $mgr_ready/$mgr_pods"
else
    print_status "ERROR" "No manager pods are running"
fi

# 7. Check CSI drivers
echo -e "\n${BLUE}🔌 CSI Driver Status${NC}"
echo "===================="

# Check RBD CSI
rbd_provisioner=$(kubectl -n rook-ceph get pods -l app=csi-rbdplugin-provisioner --no-headers | grep "Running" | wc -l)
rbd_plugin=$(kubectl -n rook-ceph get daemonset csi-rbdplugin -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [ "$rbd_provisioner" -gt 0 ]; then
    print_status "OK" "RBD CSI provisioner running: $rbd_provisioner pods"
else
    print_status "ERROR" "RBD CSI provisioner not running"
fi

if [ "$rbd_plugin" -gt 0 ]; then
    print_status "OK" "RBD CSI plugin running: $rbd_plugin nodes"
else
    print_status "ERROR" "RBD CSI plugin not running"
fi

# 8. Check storage classes
echo -e "\n${BLUE}💽 Storage Classes${NC}"
echo "=================="

storage_classes=$(kubectl get storageclass | grep ceph | wc -l)
if [ "$storage_classes" -gt 0 ]; then
    print_status "OK" "Found $storage_classes Ceph storage classes"
    kubectl get storageclass | grep ceph
else
    print_status "ERROR" "No Ceph storage classes found"
fi

# 9. Performance check
echo -e "\n${BLUE}⚡ Performance Metrics${NC}"
echo "======================"

if kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd perf >/dev/null 2>&1; then
    print_status "INFO" "OSD Performance metrics:"
    kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd perf
else
    print_status "WARN" "Cannot retrieve performance metrics"
fi

# 10. Check for recent alerts
echo -e "\n${BLUE}🚨 Recent Events${NC}"
echo "================="

print_status "INFO" "Recent events in rook-ceph namespace:"
kubectl get events -n rook-ceph --sort-by='.lastTimestamp' | tail -10

# 11. Summary and recommendations
echo -e "\n${BLUE}📋 Summary and Recommendations${NC}"
echo "==============================="

print_status "INFO" "Health check completed at $(date)"
echo -e "\n${YELLOW}Recommended actions:${NC}"
echo "1. Monitor storage utilization and plan capacity expansion if >80%"
echo "2. Investigate any unhealthy placement groups"
echo "3. Ensure all OSDs are up and in the cluster"
echo "4. Check backup job status and verify snapshots are being created"
echo "5. Review Grafana dashboards for performance trends"

echo -e "\n${GREEN}Health check complete!${NC}"
echo "For detailed troubleshooting, run:"
echo "  kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph status"
echo "  kubectl -n rook-ceph logs deployment/rook-ceph-operator"
