# Node Health Check Configuration

This directory contains NodeHealthCheck configurations for different node types in the cluster.

## Node Types

### 1. Proxmox VMs (work-00, work-01, work-02, work-03, ctrl-01)
- **Selector**: `topology.kubernetes.io/zone: pve`
- **Health Check**: nodehealthcheck-proxmox.yaml
- **Remediation**:
  - Order 1: Self-node remediation (watchdog-based)
  - Order 2: Proxmox API fencing (via fence_proxmox agent)
- **Threshold**: 5 minutes unhealthy before remediation

### 2. Bare Metal (melusine)
- **Selector**: `topology.kubernetes.io/zone: external` + `node.kubernetes.io/instance-type: external`
- **Health Check**: nodehealthcheck-baremetal.yaml
- **Remediation**:
  - Order 1: Self-node remediation (watchdog-based)
  - Order 2: IPMI fencing (via fence_ipmilan agent)
- **Threshold**: 5 minutes unhealthy before remediation

### 3. UnRAID Worker (unraid-worker)
- **Selector**: `kubernetes.io/hostname: unraid-worker`
- **Health Check**: nodehealthcheck-unraid.yaml
- **Remediation**:
  - Order 1: Self-node remediation only (longer timeout due to VM nature)
- **Threshold**: 10 minutes unhealthy before remediation

## Node Labeling Requirements

Ensure nodes are labeled correctly for the health checks to work:

```bash
# Proxmox VMs (should already have this label)
kubectl label node work-00 topology.kubernetes.io/zone=pve --overwrite
kubectl label node work-01 topology.kubernetes.io/zone=pve --overwrite
kubectl label node work-02 topology.kubernetes.io/zone=pve --overwrite
kubectl label node work-03 topology.kubernetes.io/zone=pve --overwrite
kubectl label node ctrl-01 topology.kubernetes.io/zone=pve --overwrite

# Bare Metal (melusine) - already has correct labels
kubectl label node melusine topology.kubernetes.io/zone=external --overwrite
kubectl label node melusine node.kubernetes.io/instance-type=external --overwrite

# UnRAID Worker - already labeled by hostname
```

## Credentials Required

### IPMI Credentials (for bare metal)
Stored in: `ipmi-credentials.sops.yaml`
- IPMI_HOST
- IPMI_USERNAME
- IPMI_PASSWORD

### Proxmox Credentials (for VMs)
Stored in: `proxmox-fence-credentials.sops.yaml`
- api-password: Proxmox API token or password

## How It Works

1. **NodeHealthCheck** monitors nodes matching the selector
2. When a node is unhealthy for the specified duration, it creates a remediation CR
3. **SelfNodeRemediation** agent on the node attempts to reboot using watchdog
4. If that fails, **FenceAgentsRemediation** uses the appropriate fencing agent:
   - Proxmox VMs: fence_proxmox API call
   - Bare metal: fence_ipmilan IPMI command
   - UnRAID: Self-node only (manual intervention recommended)

## Monitoring

Check remediation status:
```bash
# View node health checks
kubectl get nodehealthcheck -n medik8s-system

# View active remediations
kubectl get selfnoderemediation -n medik8s-system
kubectl get fenceagentsremediation -n medik8s-system

# Check events
kubectl get events -n medik8s-system --sort-by='.lastTimestamp'
```

## Alerts

Set up alerts for:
- Nodes in NotReady state for > 5 minutes
- Failed remediations
- Multiple nodes becoming unhealthy simultaneously (split-brain scenario)
