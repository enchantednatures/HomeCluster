#!/bin/bash

# Ceph Performance Tuning Script
# This script applies performance optimizations to the Ceph cluster

set -e

echo "⚡ Ceph Performance Tuning Script"
echo "================================="

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

# Check if toolbox is available
if ! kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph status >/dev/null 2>&1; then
    print_status "ERROR" "Cannot connect to Ceph toolbox. Ensure the cluster is healthy."
    exit 1
fi

print_status "INFO" "Starting performance tuning at $(date)"

# 1. Optimize OSD settings
echo -e "\n${BLUE}🔧 OSD Performance Tuning${NC}"
echo "=========================="

print_status "INFO" "Applying OSD performance optimizations..."

# Set OSD configuration for better performance
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd osd_memory_target 4294967296  # 4GB
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd osd_memory_cache_min 134217728  # 128MB
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd bluestore_cache_autotune true
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd bluestore_cache_kv_ratio 0.2
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd bluestore_cache_meta_ratio 0.8

# Optimize BlueStore settings
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd bluestore_min_alloc_size_ssd 4096
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd bluestore_prefer_deferred_size_ssd 32768
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd bluestore_compression_mode none  # Disable for performance

# Optimize threading
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd osd_op_num_threads_per_shard 2
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set osd osd_op_num_shards 8

print_status "OK" "OSD performance settings applied"

# 2. Optimize client settings
echo -e "\n${BLUE}🔧 Client Performance Tuning${NC}"
echo "============================="

print_status "INFO" "Applying client performance optimizations..."

# Optimize RBD cache settings
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set client rbd_cache true
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set client rbd_cache_size 67108864  # 64MB
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set client rbd_cache_max_dirty 50331648  # 48MB
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set client rbd_cache_target_dirty 33554432  # 32MB
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set client rbd_cache_writethrough_until_flush true

print_status "OK" "Client performance settings applied"

# 3. Optimize placement group settings
echo -e "\n${BLUE}🔧 Placement Group Optimization${NC}"
echo "================================"

print_status "INFO" "Optimizing placement group settings..."

# Enable PG autoscaler for all pools
pools=$(kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd lspools | awk '{print $2}')
for pool in $pools; do
    if [ -n "$pool" ]; then
        kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd pool set "$pool" pg_autoscale_mode on
        print_status "INFO" "Enabled PG autoscaler for pool: $pool"
    fi
done

# Set target ratio for main block pool
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd pool set ceph-blockpool target_size_ratio 0.5

print_status "OK" "Placement group optimization completed"

# 4. Optimize monitor settings
echo -e "\n${BLUE}🔧 Monitor Optimization${NC}"
echo "======================="

print_status "INFO" "Applying monitor optimizations..."

# Optimize monitor store settings
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set mon mon_osd_down_out_interval 600  # 10 minutes
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set mon mon_pg_warn_min_per_osd 10
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set mon mon_pg_warn_max_per_osd 300

print_status "OK" "Monitor optimization completed"

# 5. Network optimization
echo -e "\n${BLUE}🔧 Network Optimization${NC}"
echo "======================="

print_status "INFO" "Applying network optimizations..."

# Optimize network settings
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set global ms_tcp_nodelay true
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set global ms_tcp_rcvbuf 131072
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set global ms_initial_backoff 0.2
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph config set global ms_max_backoff 15.0

print_status "OK" "Network optimization completed"

# 6. Check and display current performance baseline
echo -e "\n${BLUE}📊 Performance Baseline${NC}"
echo "======================="

print_status "INFO" "Collecting performance baseline metrics..."

# Display current OSD performance
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd perf

# Display pool statistics
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph osd pool stats

# Display cluster performance
kubectl -n rook-ceph exec deployment/rook-ceph-tools -- ceph daemonperf osd

print_status "INFO" "Performance baseline collected"

# 7. Recommendations
echo -e "\n${BLUE}📋 Performance Recommendations${NC}"
echo "==============================="

print_status "INFO" "Performance tuning completed at $(date)"
echo -e "\n${YELLOW}Additional recommendations:${NC}"
echo "1. Monitor cluster performance with Grafana dashboards"
echo "2. Consider NVMe devices for metadata and WAL if available"
echo "3. Ensure adequate CPU and memory resources for OSD pods"
echo "4. Use dedicated network interfaces for Ceph traffic if possible"
echo "5. Regularly run 'ceph osd perf' to monitor latency trends"
echo "6. Consider SSD-only pools for latency-sensitive workloads"
echo "7. Monitor PG distribution and rebalance if needed"

echo -e "\n${GREEN}Performance tuning complete!${NC}"
echo "Monitor the cluster for 24-48 hours to evaluate impact."
echo "Use the health check script to verify cluster stability."
