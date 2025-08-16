#!/bin/bash

# Clean Ceph devices on all nodes
# This script creates jobs to clean storage devices on each node

echo "🧹 Cleaning Ceph Storage Devices..."
echo "=================================="

for node in work-00 work-01 work-02; do
    echo "Cleaning devices on $node..."

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: clean-device-$node
  namespace: default
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: $node
      hostNetwork: true
      restartPolicy: Never
      containers:
      - name: device-cleaner
        image: alpine:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          apk add --no-cache util-linux
          echo "Cleaning device signatures on /dev/sdb..."
          wipefs --all /dev/sdb || true
          dd if=/dev/zero of=/dev/sdb bs=1M count=100 || true
          echo "Device cleaning completed on $node"
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-dev
          mountPath: /dev
      volumes:
      - name: host-dev
        hostPath:
          path: /dev
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
EOF
done

echo "Waiting for cleaning jobs to complete..."
sleep 10

# Wait for all jobs to complete
for node in work-00 work-01 work-02; do
    kubectl wait --for=condition=complete job/clean-device-$node --timeout=300s
    kubectl logs job/clean-device-$node
    kubectl delete job clean-device-$node
done

echo "✅ Device cleaning completed on all nodes"
