# AGENTS.md - HomeCluster Repository Guidelines

## Architecture Overview
**Infrastructure**: Talos Kubernetes cluster on Proxmox VMs, managed via Terraform/Tofu
**Service Mesh**: Istio (migrating from Nginx Ingress, currently has Cilium compatibility issues)
**CNI**: Cilium for networking and security policies
**DNS**: external-dns with Cloudflare integration
**Ingress**: Cloudflare Tunnels for external access
**Serverless**: KNative for serverless workloads
**Storage**: External MinIO for object storage, OpenEBS for persistent volumes
**Observability**: Grafana, Prometheus (kube-prometheus-stack), Tempo, Loki

## Data Systems Operators
- **CloudNative-PG**: PostgreSQL operator for database workloads
- **Strimzi**: Apache Kafka operator for event streaming
- **ArangoDB Operator**: Multi-model database deployments
- **DragonflyDB Operator**: Redis-compatible in-memory datastore
- **Elastic Operator**: Elasticsearch and Kibana deployments

## Build/Test/Lint Commands
- `task default` - List all available tasks
- `task configure` - Configure repository from bootstrap vars and validate
- `task kubernetes:kubeconform` - Validate all Kubernetes manifests
- `task kubernetes:resources` - List common cluster resources
- `task flux:apply path=<app-path>` - Apply specific Flux resources
- `task flux:reconcile` - Force update Flux to pull changes from git
- `task sops:encrypt` - Encrypt all SOPS secrets
- `task sops:decrypt` - Decrypt all SOPS files

## Code Style Guidelines
- **YAML**: 2-space indentation, LF line endings, UTF-8 encoding
- **File Structure**: Follow GitOps patterns - `/kubernetes/apps/<namespace>/<app>/` structure
- **Kubernetes Manifests**: Include yaml-language-server schema comments for validation
- **Secrets**: Always encrypt with SOPS/Age - never commit unencrypted sensitive data
- **Naming**: Use kebab-case for files, resources follow Kubernetes conventions
- **Comments**: Use `#` for YAML comments, include schema validation headers
- **App Structure**: Each app needs: `namespace.yaml`, `kustomization.yaml`, `ks.yaml`, and `app/` directory
- **HelmReleases**: Include proper versioning, remediation settings, and cleanup policies

## Istio Service Communication
- **Cross-namespace communication**: Services may need ServiceEntry configurations
- **Service discovery**: Use full FQDN format: `service-name.namespace.svc.cluster.local:port`
- **Port specifications**: Always specify explicit ports in service URLs and ServiceEntry configurations
- **Common service ports**: Prometheus: 9090, Grafana: 80/3000, Tempo: 3200/16686, AlertManager: 9093

## Critical Operational Requirements
- **GitOps Only**: ALL changes must be committed and pushed to git - no direct cluster access
- **Flux Sync**: Changes only take effect after Flux reconciles from git repository
- **SOPS Encryption**: All secrets must be encrypted before committing
- **Validation**: All manifests must pass kubeconform validation before deployment
- **Istio Migration**: Consider service mesh implications when adding new services