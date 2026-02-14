# System Architecture

## Table of Contents

- [Overview](#overview)
- [High-Level Architecture](#high-level-architecture)
- [Infrastructure Layer](#infrastructure-layer)
- [Platform Layer](#platform-layer)
- [Application Layer](#application-layer)
- [Data Flow](#data-flow)
- [Network Architecture](#network-architecture)
- [Security Architecture](#security-architecture)
- [Deployment Pipeline](#deployment-pipeline)

## Overview

The HomeCluster architecture is designed as a multi-layered system that provides enterprise-grade capabilities for home lab environments. The architecture follows cloud-native principles with GitOps-driven deployments, service mesh networking, and comprehensive observability.

This repository implements a **home‑lab Kubernetes cluster** using the following core components:

- **Talos** as the operating system for the nodes (running on Proxmox VMs)
- **Kubernetes** (Talos‑managed) with **Flux** for GitOps‑driven configuration
- **Cilium** for networking and security policies
- **Istio** as the service mesh (ambient mode -- no sidecars)
- **External‑DNS** with Cloudflare for DNS management
- **Cloudflare Tunnels** for external ingress
- **KNative** for server‑less workloads
- **Rook‑Ceph** for distributed block/object storage and **OpenEBS** for local persistent volumes
- **Observability stack**: Grafana, Prometheus (kube‑prometheus‑stack), Loki, Tempo

The repository follows a **GitOps** model: all changes are made via Git, and Flux reconciles the state to the cluster. Secrets are encrypted with **SOPS** and **Age**.

## High-Level Architecture

```mermaid
graph TB
    subgraph "External Services"
        CF[Cloudflare]
        GH[GitHub Repository]
        REG[Container Registry]
    end

    subgraph "Home Network"
        subgraph "Kubernetes Cluster"
            subgraph "Infrastructure Layer"
                K8S[Kubernetes Control Plane]
                CILIUM[Cilium CNI]
                STORAGE[Rook-Ceph + OpenEBS Storage]
                ISTIO[Istio Service Mesh]
            end

            subgraph "Platform Services"
                FLUX[Flux GitOps]
                CERT[Cert-Manager]
                DNS[External-DNS]
                TUNNEL[Cloudflare Tunnel]
                AUTH[Authentik]
            end

            subgraph "Observability Stack"
                PROM[Prometheus]
                GRAF[Grafana]
                TEMPO[Tempo]
                LOKI[Loki]
            end

            subgraph "Data Services"
                PG[PostgreSQL]
                KAFKA[Apache Kafka]
                ARANGO[ArangoDB]
                REDIS[DragonflyDB]
            end

            subgraph "Applications"
                APPS[User Applications]
                KNATIVE[Serverless Apps]
                HARBOR[Container Registry]
            end
        end
    end

    CF --> TUNNEL
    GH --> FLUX
    REG --> K8S

    FLUX --> K8S
    K8S --> CILIUM
    K8S --> STORAGE
    K8S --> ISTIO

    ISTIO --> CERT
    ISTIO --> DNS
    ISTIO --> AUTH

    PROM --> GRAF
    GRAF --> TEMPO
    GRAF --> LOKI

    APPS --> PG
    APPS --> KAFKA
    APPS --> ARANGO
    APPS --> REDIS
```

## Infrastructure Layer

### Kubernetes Distribution
- **Talos**: Immutable, minimal operating system purpose-built for Kubernetes
- **High Availability**: Multi-master setup with etcd clustering
- **Provisioning**: OpenTofu (Terraform-compatible) on Proxmox VMs

### Container Network Interface (CNI)
- **Cilium**: eBPF-based networking and security
- **Features**:
  - Network policies and security
  - Load balancing and service mesh
  - Observability and monitoring
  - Cluster mesh capabilities

### Storage
- **Rook-Ceph**: Distributed storage providing block (RBD) and object storage
  - NVMe-optimized OSDs
  - CephFS for shared filesystems
  - Object store for S3-compatible access
- **OpenEBS**: Container-attached storage for local persistent volumes
- **Storage Classes**:
  - Ceph RBD for replicated block storage
  - Local PV for high-performance workloads
  - Dynamic provisioning

### Service Mesh
- **Istio (Ambient Mode)**: Advanced traffic management and security without sidecar proxies
- **Components**:
  - Ztunnel for Layer 4 traffic handling
  - Istiod for configuration and certificate management
  - Istio CNI for pod network setup
  - Kiali for service mesh observability

## Platform Layer

### GitOps Engine
```mermaid
graph LR
    subgraph "GitOps Workflow"
        GIT[Git Repository] --> FLUX[Flux Controller]
        FLUX --> KUST[Kustomization]
        KUST --> HELM[Helm Releases]
        HELM --> K8S[Kubernetes API]

        FLUX --> SOPS[SOPS Decryption]
        SOPS --> SECRETS[Kubernetes Secrets]
    end
```

### Certificate Management
- **Cert-Manager**: Automated TLS certificate provisioning
- **Let's Encrypt**: Free SSL certificates
- **Cloudflare DNS Challenge**: Wildcard certificate support

### DNS Management
- **External-DNS**: Automated DNS record management
- **Cloudflare Integration**: Dynamic DNS updates
- **Split DNS**: Internal and external resolution

### Identity and Access
- **Authentik**: Identity provider and SSO
- **OAuth2/OIDC**: Modern authentication protocols
- **RBAC Integration**: Kubernetes role-based access control

## Application Layer

### Database Operators
```mermaid
graph TB
    subgraph "Database Ecosystem"
        CNPG[CloudNative-PG<br/>PostgreSQL Operator]
        STRIMZI[Strimzi<br/>Kafka Operator]
        ARANGO_OP[ArangoDB Operator]
        DRAGONFLY[DragonflyDB Operator]
        ELASTIC[Elastic Operator]

        subgraph "Database Instances"
            PG_CLUSTER[PostgreSQL Clusters]
            KAFKA_CLUSTER[Kafka Clusters]
            ARANGO_CLUSTER[ArangoDB Deployments]
            REDIS_CLUSTER[Redis-Compatible Cache]
            ELASTIC_CLUSTER[Elasticsearch Deployments]
        end

        CNPG --> PG_CLUSTER
        STRIMZI --> KAFKA_CLUSTER
        ARANGO_OP --> ARANGO_CLUSTER
        DRAGONFLY --> REDIS_CLUSTER
        ELASTIC --> ELASTIC_CLUSTER
    end
```

### Serverless Platform
- **KNative Serving**: Serverless container platform
- **KNative Eventing**: Event-driven architecture
- **Auto-scaling**: Scale-to-zero capabilities
- **Traffic Management**: Blue-green and canary deployments

### Development Tools
- **Harbor**: Enterprise container registry
- **Tekton**: Cloud-native CI/CD pipelines
- **Telepresence**: Local development against remote cluster

## Data Flow

### Request Flow
```mermaid
sequenceDiagram
    participant User
    participant Cloudflare
    participant Tunnel
    participant Istio
    participant App
    participant Database

    User->>Cloudflare: HTTPS Request
    Cloudflare->>Tunnel: Forward Request
    Tunnel->>Istio: Route to Service
    Istio->>App: Load Balance
    App->>Database: Query Data
    Database-->>App: Return Data
    App-->>Istio: Response
    Istio-->>Tunnel: Response
    Tunnel-->>Cloudflare: Response
    Cloudflare-->>User: HTTPS Response
```

### GitOps Deployment Flow
```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Git as Git Repository
    participant Flux as Flux Controller
    participant K8s as Kubernetes API
    participant App as Application

    Dev->>Git: Push Changes
    Git->>Flux: Webhook/Poll
    Flux->>Git: Fetch Changes
    Flux->>Flux: Decrypt Secrets
    Flux->>K8s: Apply Manifests
    K8s->>App: Deploy/Update
    App-->>Flux: Status
    Flux-->>Git: Update Status
```

## Network Architecture

### Network Topology
```mermaid
graph TB
    subgraph "External Network"
        INTERNET[Internet]
        CF_EDGE[Cloudflare Edge]
    end

    subgraph "Home Network"
        ROUTER[Home Router]
        DNS_SERVER[Pi-hole DNS]

        subgraph "Kubernetes Network"
            subgraph "Node Network"
                NODE1[Node 1<br/>192.168.1.10]
                NODE2[Node 2<br/>192.168.1.11]
                NODE3[Node 3<br/>192.168.1.12]
            end

            subgraph "Pod Network"
                POD_CIDR[Pod CIDR<br/>10.42.0.0/16]
            end

            subgraph "Service Network"
                SVC_CIDR[Service CIDR<br/>10.43.0.0/16]
            end
        end
    end

    INTERNET --> CF_EDGE
    CF_EDGE --> ROUTER
    ROUTER --> DNS_SERVER
    ROUTER --> NODE1
    ROUTER --> NODE2
    ROUTER --> NODE3

    NODE1 --> POD_CIDR
    NODE2 --> POD_CIDR
    NODE3 --> POD_CIDR

    POD_CIDR --> SVC_CIDR
```

### Service Mesh Traffic Management
- **Ingress Gateway**: Entry point for external traffic
- **Virtual Services**: Traffic routing rules
- **Destination Rules**: Load balancing and circuit breaking
- **Service Entries**: External service integration

## Security Architecture

### Security Layers
```mermaid
graph TB
    subgraph "Security Layers"
        subgraph "Network Security"
            FW[Firewall Rules]
            NP[Network Policies]
            MTLS[mTLS Encryption]
        end

        subgraph "Identity & Access"
            RBAC[Kubernetes RBAC]
            SSO[Single Sign-On]
            JWT[JWT Tokens]
        end

        subgraph "Data Security"
            SOPS_ENC[SOPS Encryption]
            AGE_KEY[Age Keys]
            TLS_CERTS[TLS Certificates]
        end

        subgraph "Runtime Security"
            PSP[Pod Security Policies]
            ADMISSION[Admission Controllers]
            SCAN[Image Scanning]
        end
    end
```

### Secret Management
- **SOPS**: Secrets encryption at rest
- **Age**: Modern encryption tool
- **Kubernetes Secrets**: Runtime secret injection
- **External Secrets**: Integration with external secret stores

## Deployment Pipeline

### CI/CD Architecture
```mermaid
graph LR
    subgraph "Development"
        DEV[Developer]
        IDE[IDE/Editor]
    end

    subgraph "Source Control"
        GIT[Git Repository]
        PR[Pull Request]
    end

    subgraph "CI Pipeline"
        VALIDATE[Validate YAML]
        LINT[Lint Code]
        TEST[Run Tests]
        BUILD[Build Images]
    end

    subgraph "CD Pipeline"
        FLUX[Flux Sync]
        DEPLOY[Deploy to Cluster]
        MONITOR[Monitor Health]
    end

    DEV --> IDE
    IDE --> GIT
    GIT --> PR
    PR --> VALIDATE
    VALIDATE --> LINT
    LINT --> TEST
    TEST --> BUILD
    BUILD --> FLUX
    FLUX --> DEPLOY
    DEPLOY --> MONITOR
```

### Deployment Stages
1. **Infrastructure**: Core Kubernetes components and operators
2. **Core**: Essential platform services (Flux, cert-manager, etc.)
3. **Applications**: User applications and workloads

### Health Checks and Monitoring
- **Readiness Probes**: Application startup validation
- **Liveness Probes**: Runtime health monitoring
- **Prometheus Metrics**: Performance and health metrics
- **Grafana Dashboards**: Visual monitoring and alerting

## Scalability Considerations

### Horizontal Scaling
- **Pod Autoscaling**: HPA based on CPU/memory metrics
- **Cluster Autoscaling**: Node scaling based on resource demands
- **Service Mesh**: Distributed load balancing

### Vertical Scaling
- **Resource Requests/Limits**: Proper resource allocation
- **Quality of Service**: Guaranteed, Burstable, and BestEffort classes
- **Storage Scaling**: Dynamic volume expansion

### Performance Optimization
- **Resource Quotas**: Namespace-level resource management
- **Affinity Rules**: Pod placement optimization
- **Caching Strategies**: Redis/DragonflyDB for application caching
