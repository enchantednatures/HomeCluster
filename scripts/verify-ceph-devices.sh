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

    # Cleanup
    kubectl delete pod device-check-$node --ignore-not-found=true
done

echo -e "\n📝 Summary:"
echo "==========="
echo "1. Ensure all nodes have /dev/sdb available"
echo "2. Clean any existing signatures with 'wipefs --all /dev/sdb'"
echo "3. Verify minimum 10GB free space per device"
echo "4. Check that nodes are labeled correctly for Ceph"
