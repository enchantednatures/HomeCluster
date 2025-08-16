# InfluxDB GitOps Deployment Summary

## 📁 Created Files Structure

```
kubernetes/apps/monitoring/
├── namespace.yaml                    # Monitoring namespace with Istio injection
├── kustomization.yaml               # Namespace-level kustomization
└── influxdb/
    ├── ks.yaml                      # Flux Kustomization resource
    ├── README.md                    # Complete documentation
    ├── DEPLOYMENT.md               # This file
    ├── validate.sh                 # Validation script (executable)
    └── app/
        ├── kustomization.yaml      # App-level kustomization
        ├── helmrelease.yaml        # Main InfluxDB HelmRelease
        ├── secret.sops.yaml        # SOPS-encrypted credentials
        ├── servicemonitor.yaml     # Prometheus monitoring integration
        ├── virtualservice.yaml     # Istio external access
        ├── destinationrule.yaml    # Istio traffic policies
        ├── pvc.yaml               # Persistent volume claim
        ├── service.yaml           # Internal cluster service
        ├── configmap.yaml         # InfluxDB configuration
        ├── networkpolicy.yaml     # Network security policies
        ├── grafana-dashboard.yaml # Grafana dashboard for InfluxDB
        └── telegraf-proxmox.yaml  # Telegraf configuration for Proxmox
```

## 🚀 Key Features Implemented

### ✅ Core Requirements Met

- **HomeCluster Structure**: Follows `/kubernetes/apps/<namespace>/<app>/` pattern
- **Namespace**: `monitoring` with Istio injection enabled
- **HelmRelease**: Uses official `influxdb2` chart (v2.1.2)
- **Storage**: OpenEBS persistent volumes (50GB)
- **RBAC**: Dedicated service account with proper security context
- **SOPS Encryption**: All sensitive data encrypted
- **Remediation**: Proper cleanup and retry policies

### 🔒 Security Configuration

- **SOPS-encrypted secrets** for admin password and API token
- **NetworkPolicy** restricting access to authorized services
- **Security context** with non-root user (1000:1000)
- **Pod security context** with fsGroup configuration
- **Istio service mesh** integration for secure communication

### 📊 Monitoring & Observability

- **ServiceMonitor** for Prometheus metrics collection
- **Grafana dashboard** with InfluxDB overview metrics
- **Health checks** (liveness, readiness, startup probes)
- **Resource monitoring** with requests/limits configured
- **Metrics endpoint** exposed at `/metrics`

### 🌐 Istio Service Mesh

- **VirtualService** for external access via `influxdb.${SECRET_DOMAIN}`
- **DestinationRule** with connection pooling and circuit breaker
- **Gateway integration** with external-gateway
- **Traffic policies** optimized for database workloads

### 📈 Proxmox Integration

- **Database setup** optimized for metrics collection
- **Multiple buckets** with different retention policies:
  - `proxmox` (30 days) - Main Proxmox metrics
  - `system-metrics` (7 days) - System-level metrics
  - `application-metrics` (14 days) - Application metrics
  - `network-metrics` (7 days) - Network metrics
- **Telegraf configuration** for Proxmox VE metrics collection
- **Init scripts** for automatic bucket creation

## 🔧 Configuration Details

### InfluxDB Settings
```yaml
Organization: homelab
Admin User: admin
Default Bucket: proxmox
Retention: 30 days
Storage: 50GB OpenEBS
Resources: 512Mi-2Gi RAM, 250m-1000m CPU
```

### Access URLs
```yaml
Web UI: https://influxdb.${SECRET_DOMAIN}
Internal API: http://influxdb-influxdb2.monitoring.svc.cluster.local:8086
Health Check: http://influxdb-internal.monitoring.svc.cluster.local:8086/health
Metrics: http://influxdb-internal.monitoring.svc.cluster.local:8086/metrics
```

### Buckets Configuration
```yaml
proxmox: 30d retention (main Proxmox metrics)
system-metrics: 7d retention (system monitoring)
application-metrics: 14d retention (app monitoring)
network-metrics: 7d retention (network monitoring)
```

## 📋 Deployment Steps

### 1. Pre-deployment Validation
```bash
cd kubernetes/apps/monitoring/influxdb
./validate.sh
```

### 2. Encrypt Secrets (Required)
```bash
# Update the secret with real values before encrypting
nano app/secret.sops.yaml

# Encrypt with SOPS
sops -e -i app/secret.sops.yaml
```

### 3. Deploy via GitOps
```bash
# Commit and push to trigger Flux reconciliation
git add kubernetes/apps/monitoring/
git commit -m "feat(monitoring): add InfluxDB for Proxmox metrics collection"
git push origin main
```

### 4. Monitor Deployment
```bash
# Watch Flux reconciliation
flux get kustomizations -n flux-system | grep influxdb

# Monitor pod deployment
kubectl get pods -n monitoring -l app.kubernetes.io/name=influxdb2 -w

# Check service status
kubectl get svc -n monitoring
```

### 5. Verify Access
```bash
# Test internal connectivity
kubectl exec -n monitoring deployment/influxdb-influxdb2 -- influx ping

# Check external access (after DNS propagation)
curl -k https://influxdb.${SECRET_DOMAIN}/health
```

## 🔧 Post-Deployment Configuration

### 1. Configure Proxmox Hosts
Install and configure Telegraf on each Proxmox node using the provided configuration in `telegraf-proxmox.yaml`.

### 2. Set Up Grafana Data Source
Add InfluxDB as a data source in Grafana:
```yaml
Type: InfluxDB
URL: http://influxdb-influxdb2.monitoring.svc.cluster.local:8086
Organization: homelab
Token: <admin-token-from-secret>
Default Bucket: proxmox
```

### 3. Import Dashboards
The Grafana dashboard is automatically provisioned via the ConfigMap with label `grafana_dashboard: "1"`.

## 🚨 Troubleshooting

### Common Issues
1. **Pod stuck in Pending**: Check PVC and storage class availability
2. **Init container fails**: Verify InfluxDB startup and health endpoint
3. **External access fails**: Check Istio Gateway and DNS configuration
4. **Metrics not appearing**: Verify ServiceMonitor labels and Prometheus config

### Debug Commands
```bash
# Check pod logs
kubectl logs -n monitoring -l app.kubernetes.io/name=influxdb2 -f

# Describe pod for events
kubectl describe pod -n monitoring -l app.kubernetes.io/name=influxdb2

# Check Flux reconciliation status
flux get kustomizations -n flux-system influxdb

# Validate Istio configuration
istioctl analyze -n monitoring
```

## 📚 Next Steps

1. **Configure Telegraf** on Proxmox hosts using the provided configuration
2. **Set up alerting** rules for InfluxDB health and performance
3. **Implement backup strategy** for InfluxDB data
4. **Configure retention policies** based on your monitoring needs
5. **Add custom dashboards** for specific Proxmox metrics visualization

## 🔄 GitOps Compliance

This deployment is fully GitOps compliant:
- ✅ All changes tracked in Git
- ✅ Declarative configuration
- ✅ Automated reconciliation via Flux
- ✅ SOPS encryption for secrets
- ✅ Proper resource labeling and annotations
- ✅ Validation scripts included
- ✅ Documentation and troubleshooting guides
