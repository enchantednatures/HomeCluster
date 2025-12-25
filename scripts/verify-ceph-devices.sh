#!/bin/bash

# Device verification script for Ceph nodes
# Run this script to verify device availability before deploying Ceph

echo "🔍 Verifying Ceph Storage Devices..."
echo "===================================="

# Check each ready worker node
for node in work-00 work-01 work-02; do
    echo -e "\n📋 Checking node: $node"
    echo "------------------------"

    # Check if node exists and is ready
    if kubectl get node $node &>/dev/null; then
        node_status=$(kubectl get node $node -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        if [ "$node_status" = "True" ]; then
            echo "✓ Node $node is Ready"
        else
            echo "✗ Node $node is NOT Ready (status: $node_status)"
            continue
        fi
    else
        echo "✗ Node $node not found"
        continue
    fi

    # Create a debug pod to check devices
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: device-check-$node
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  hostNetwork: true
  hostPID: true
  containers:
  - name: device-check
    image: alpine:latest
    command: ["/bin/sh", "-c", "sleep 60"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-dev
      mountPath: /host/dev
      readOnly: true
  volumes:
  - name: host-dev
    hostPath:
      path: /dev
  restartPolicy: Never
  tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists
EOF

    # Wait for pod to be ready
    kubectl wait --for=condition=Ready pod/device-check-$node --timeout=60s

    # Check for available block devices
    echo "Available block devices on $node:"
    kubectl exec device-check-$node -- ls -la /host/dev/sd* /host/dev/nvme* 2>/dev/null || echo "  No additional storage devices found"

    # Check NVMe devices specifically
    echo "NVMe devices on $node:"
    kubectl exec device-check-$node -- nvme list 2>/dev/null || echo "  No NVMe devices found or nvme-cli not available"

    # Check if /dev/sdb exists and is clean
    if kubectl exec device-check-$node -- test -b /host/dev/sdb 2>/dev/null; then
        echo "✓ /dev/sdb exists on $node"

        # Check for existing filesystems
        fs_check=$(kubectl exec device-check-$node -- blkid /host/dev/sdb 2>/dev/null || echo "clean")
        if [ "$fs_check" = "clean" ]; then
            echo "✓ /dev/sdb appears to be clean"
        else
            echo "⚠ /dev/sdb has existing data: $fs_check"
            echo "  Run: wipefs --all /dev/sdb on $node"
        fi

        # Check device size
        size=$(kubectl exec device-check-$node -- blockdev --getsize64 /host/dev/sdb 2>/dev/null || echo "unknown")
        if [ "$size" != "unknown" ]; then
            size_gb=$((size / 1024 / 1024 / 1024))
            echo "ℹ Device size: ${size_gb}GB"
        fi
    else
        echo "✗ /dev/sdb not found on $node"
    fi

    # Check NVMe devices
    nvme_devices=$(kubectl exec device-check-$node -- ls /host/dev/nvme* 2>/dev/null | wc -l)
    if [ "$nvme_devices" -gt 0 ]; then
        echo "✓ NVMe devices found on $node"

        # List all NVMe devices
        kubectl exec device-check-$node -- nvme list

        # Check each NVMe device
        for nvme_dev in $(kubectl exec device-check-$node -- ls /host/dev/nvme*n* 2>/dev/null); do
            dev_name=$(basename $nvme_dev)
            echo "  Checking $dev_name:"

            # Check device health
            health_info=$(kubectl exec device-check-$node -- nvme smart-log $nvme_dev 2>/dev/null | grep -E "(temperature|available_spare|percentage_used|media_errors)" || echo "Health check failed")
            if echo "$health_info" | grep -q "Health check failed"; then
                echo "  ⚠ Unable to check $dev_name health (nvme-cli may not be available)"
            else
                echo "  ℹ Health status for $dev_name:"
                echo "$health_info" | while read line; do echo "    $line"; done
            fi

            # Check device size
            size=$(kubectl exec device-check-$node -- blockdev --getsize64 $nvme_dev 2>/dev/null || echo "unknown")
            if [ "$size" != "unknown" ]; then
                size_gb=$((size / 1024 / 1024 / 1024))
                echo "  ℹ Device size: ${size_gb}GB"
            fi

            # Check for existing filesystems
            fs_check=$(kubectl exec device-check-$node -- blkid $nvme_dev 2>/dev/null || echo "clean")
            if [ "$fs_check" = "clean" ]; then
                echo "  ✓ $dev_name appears to be clean"
            else
                echo "  ⚠ $dev_name has existing data: $fs_check"
                echo "    Run: nvme format -s 1 $nvme_dev on $node"
            fi

            # Check PCIe information
            pcie_info=$(kubectl exec device-check-$node -- lspci -vvv -s $(lspci | grep -i nvme | head -1 | cut -d' ' -f1) 2>/dev/null | grep -A 5 "LnkSta" || echo "PCIe info unavailable")
            if [ "$pcie_info" != "PCIe info unavailable" ]; then
                echo "  ℹ PCIe status for $dev_name:"
                echo "$pcie_info" | while read line; do echo "    $line"; done
            fi
        done
    else
        echo "ℹ No NVMe devices found on $node"
    fi

    # Cleanup
    kubectl delete pod device-check-$node --ignore-not-found=true
done

echo -e "\n📝 Summary:"
echo "==========="
echo "1. Ensure all nodes have storage devices (/dev/sdb for SSD, /dev/nvme* for NVMe)"
echo "2. For SSD devices: Clean any existing signatures with 'wipefs --all /dev/sdb'"
echo "3. For NVMe devices: Use 'nvme format -s 1 /dev/nvmeXnX' for secure erase"
echo "4. Verify minimum 10GB free space per device"
echo "5. Check NVMe health with 'nvme smart-log' and PCIe status"
echo "6. Ensure nodes are labeled correctly for Ceph"
