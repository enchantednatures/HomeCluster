# Rook-Ceph Configuration for HomeCluster

This directory contains the complete Rook-Ceph cluster configuration optimized for the HomeCluster Talos Kubernetes environment.

## Overview

This Rook-Ceph implementation provides enterprise-grade storage for your Talos Kubernetes homelab:

- **Block Storage**: Primary storage using RBD with 3-way replication (default storage class)
- **Object Storage**: S3-compatible storage with erasure coding for efficiency
- **High Availability**: Multi-node deployment with proper anti-affinity
- **Talos Optimized**: Configured specifically for Talos Linux nodes
- **Istio Integration**: Service mesh routing for external access
- **GitOps Ready**: Full Flux CD integration with health checks
- **Security**: RBAC, network policies, and SOPS-encrypted secrets

## ⚠️ IMPORTANT: Pre-Deployment Configuration Required

Before deploying, you MUST update the following in `ceph-cluster.yaml`:

1. **Node Names**: Replace `talos-worker-1`, `talos-worker-2`, `talos-worker-3` with your actual node names
2. **Device Paths**: Replace `/dev/sdb` with your actual storage device paths
3. **Device Filter**: Adjust `deviceFilter` pattern to match your VM disk setup

```bash
# Check your node names
kubectl get nodes --show-labels | grep worker

# Check available storage devices on each node  
kubectl debug node/YOUR_NODE_NAME -it --image=busybox -- lsblk
```

## Components

### Core Resources

1. **CephCluster** (`ceph-cluster.yaml`)
   - Contains the object store configuration within the main cluster spec
   - Configured with optimized pool settings and HA gateway setup

2. **CephObjectStoreUser** (`ceph-objectstore-user.yaml`)
   - Regular user for application access
   - Limited permissions with quotas

3. **CephObjectStoreUser Admin** (`ceph-objectstore-admin-user.yaml`)
   - Administrative user for management operations
   - Full permissions without quotas

4. **StorageClass** (`ceph-bucket-storageclass.yaml`)
   - Storage classes for ObjectBucketClaims
   - Both Delete and Retain reclaim policies

### Network and Security

5. **VirtualService** (`virtual-service.yaml`)
   - Istio routing for both dashboard and object store
   - Configured for external access via `rgw.${SECRET_DOMAIN}`

6. **NetworkPolicy** (`networkpolicy.yaml`)
   - Restricts network traffic to authorized sources
   - Allows Istio, monitoring, and internal cluster communication

7. **PodDisruptionBudget** (`poddisruptionbudget.yaml`)
   - Ensures at least 1 RGW instance remains available during disruptions

### Monitoring

8. **ServiceMonitor** (`servicemonitor.yaml`)
   - Prometheus monitoring configuration for RGW metrics

## Usage

### Creating Buckets

Use ObjectBucketClaims to provision S3 buckets:

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-bucket
  namespace: my-namespace
spec:
  generateBucketName: my-app-bucket
  storageClassName: ceph-bucket
```

### Accessing Credentials

After creating an OBC, credentials are stored in a secret and config map:

```bash
# Get S3 credentials
export AWS_ACCESS_KEY_ID=$(kubectl get secret my-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode)
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret my-bucket -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 --decode)

# Get endpoint information
export AWS_HOST=$(kubectl get cm my-bucket -o jsonpath='{.data.BUCKET_HOST}')
export BUCKET_NAME=$(kubectl get cm my-bucket -o jsonpath='{.data.BUCKET_NAME}')
```

### External Access

The object store is accessible externally via:
- **URL**: `https://rgw.${SECRET_DOMAIN}`
- **S3 Alternative**: `https://s3.${SECRET_DOMAIN}`

### Client Configuration

For S3 clients, configure:
- **Endpoint**: Use the external URL above
- **Region**: `us-east-1`
- **Path-style access**: Required (virtual-hosted-style not configured)

## Security Considerations

1. **TLS**: Consider enabling TLS by configuring `sslCertificateRef` in the gateway spec
2. **Access Control**: Use separate users for different applications
3. **Network Policies**: Restrictive policies are in place - update as needed
4. **Quotas**: Regular users have quotas to prevent resource exhaustion

## Monitoring

Metrics are available at:
- **RGW Metrics**: Scraped by Prometheus via ServiceMonitor
- **Ceph Dashboard**: Available at `https://rook.${SECRET_DOMAIN}`

Key metrics to monitor:
- `ceph_rgw_req_rate` - Request rate
- `ceph_rgw_req_avg_latency` - Average latency
- `ceph_rgw_bandwidth` - Bandwidth utilization

## Troubleshooting

### Common Issues

1. **RGW pods not starting**:
   ```bash
   kubectl logs -n rook-ceph -l app=rook-ceph-rgw
   ```

2. **Cannot create buckets**:
   - Check ObjectBucketClaim status
   - Verify storage class exists
   - Check operator logs

3. **Network connectivity issues**:
   - Verify NetworkPolicy allows required traffic
   - Check Istio VirtualService configuration

### Useful Commands

```bash
# Check RGW status
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw

# Check object store status
kubectl get cephobjectstore -n rook-ceph

# Check users
kubectl get cephobjectstoreuser -n rook-ceph

# Check buckets
kubectl get objectbucketclaim -A
```

## Maintenance

### Scaling RGW Instances

To scale the number of gateway instances, update the `instances` field in `ceph-cluster.yaml`:

```yaml
gateway:
  instances: 3  # Increase from 2 to 3
```

### Resource Adjustments

Monitor resource usage and adjust limits/requests in the gateway configuration as needed.

### Pool Configuration

The current configuration uses:
- **Metadata Pool**: 3-replica for reliability
- **Data Pool**: 2+1 erasure coding for space efficiency

For higher durability requirements, consider:
- **Data Pool**: 4+2 or 8+4 erasure coding
- **Metadata Pool**: Increase replica count

## Integration with External MinIO

Since you have external MinIO for object storage, this Ceph Object Store can serve as:
1. **Internal cluster storage**: For applications that need cluster-local object storage
2. **Backup target**: For backing up data from external MinIO
3. **Development/testing**: As a test environment for S3-compatible applications
4. **Multi-tier storage**: For different storage tiers based on access patterns