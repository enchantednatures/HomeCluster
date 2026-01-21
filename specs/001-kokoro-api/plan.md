# Implementation Plan: Kokoro Text-to-Speech API Integration

**Branch**: `001-kokoro-api` | **Date**: 2026-01-20 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-kokoro-api/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Deploy Kokoro-FastAPI text-to-speech service as containerized Kubernetes workload with Istio ambient mesh integration. Users submit text via HTTP REST API and receive synthesized audio in MP3/WAV/OGG formats. No external API dependencies, authentication, or caching layers required. Service runs on-demand with retry logic via Istio VirtualService.

## Technical Context

**Language/Version**: Python (Kokoro-FastAPI container), YAML (Kubernetes manifests)  
**Primary Dependencies**: Kokoro-FastAPI container (https://github.com/remsky/Kokoro-FastAPI), Istio ambient mesh, Cilium CNI  
**Storage**: Ephemeral or persistent volume for temporary audio output (OpenEBS/Rook-Ceph) - NEEDS CLARIFICATION on volume type  
**Testing**: Integration tests via `task kubernetes:kubeconform`, manual validation post-deployment - NEEDS CLARIFICATION on automated testing approach  
**Target Platform**: Talos Kubernetes cluster on Proxmox VMs (HomeCluster environment)  
**Project Type**: Kubernetes infrastructure deployment (manifest-based GitOps)  
**Performance Goals**: <5s audio generation for 500-word inputs, <2s p95 response time, 10+ concurrent requests  
**Constraints**: No external API dependencies, no authentication required, no caching layer, 99.5% success rate for valid requests  
**Scale/Scope**: Single-service deployment, primarily English language support initially, majority of inputs <1000 words  
**Resource Requirements**: NEEDS CLARIFICATION on CPU/memory requests and limits for Kokoro container  
**Container Registry**: NEEDS CLARIFICATION on where to host Kokoro-FastAPI image (internal registry vs. public)  
**Ingress Pattern**: NEEDS CLARIFICATION on Istio Gateway vs. Cloudflare Tunnel for external access  
**Retry Configuration**: NEEDS CLARIFICATION on exact Istio VirtualService retry policy parameters (attempts, timeout, backoff)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Status**: ✅ PASS - Constitution template not yet populated with project-specific rules.

**HomeCluster GitOps Compliance** (from AGENTS.md):
- ✅ All changes via git commit/push (no direct kubectl apply)
- ✅ Flux reconciliation pattern followed
- ✅ Secrets will be encrypted with SOPS/Age before commit
- ✅ Schema validation via `task kubernetes:kubeconform` required
- ✅ YAML formatting: 2-space indent, LF endings, UTF-8, kebab-case naming
- ✅ Istio ambient mesh compatibility (VirtualService for retry logic)
- ✅ File structure: `/kubernetes/apps/<namespace>/kokoro-api/` pattern

**No Violations** - Infrastructure deployment aligns with existing cluster patterns.

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
kubernetes/apps/<namespace>/kokoro-api/
├── namespace.yaml                    # Namespace definition
├── kustomization.yaml                # Kustomization root (prune: true, targetNamespace)
├── ks.yaml                           # Flux Kustomization (in flux-system namespace)
└── app/
    ├── kustomization.yaml            # App-level kustomization
    ├── helmrelease.yaml              # HelmRelease for Kokoro-FastAPI (if using Helm)
    │                                 # OR deployment.yaml (if using raw manifests)
    ├── service.yaml                  # ClusterIP Service
    ├── virtualservice.yaml           # Istio VirtualService (retry config)
    ├── pvc.yaml                      # PersistentVolumeClaim (if needed for audio output)
    └── configmap.yaml                # ConfigMap for Kokoro configuration (if needed)
```

**Structure Decision**: Kubernetes infrastructure-only deployment (no application code). 

This follows the HomeCluster pattern:
- `/kubernetes/apps/<namespace>/kokoro-api/` structure per AGENTS.md
- GitOps workflow via FluxCD
- Schema validation: `# yaml-language-server: $schema=<url>` comments
- SOPS encryption for any secrets (though none required per clarifications)
- Istio ambient mesh integration via VirtualService
- Standard resource naming with anchor pattern (`name: &app kokoro-api`)

**Namespace Selection**: NEEDS CLARIFICATION - which namespace? Options: `default`, `media`, `ai-services`, or new namespace?

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

**No violations** - This deployment follows standard HomeCluster infrastructure patterns with no additional complexity.

---

## Phase Completion Status

### ✅ Phase 0: Outline & Research (COMPLETE)

**Artifacts Generated**:
- `research.md` - All "NEEDS CLARIFICATION" items resolved

**Key Decisions**:
1. Storage: `emptyDir` ephemeral volume (no PVC)
2. Testing: kubeconform + manual smoke tests
3. Resources: 500m/1Gi requests, 2000m/4Gi limits (to be validated)
4. Registry: ghcr.io public registry (Kokoro-FastAPI image)
5. Ingress: Istio Gateway + VirtualService (internal only initially)
6. Retry: 3 attempts, 30s timeout, exponential backoff
7. Namespace: `ai-services`

---

### ✅ Phase 1: Design & Contracts (COMPLETE)

**Artifacts Generated**:
- `data-model.md` - API request/response model + Kubernetes resource specifications
- `contracts/openapi.yaml` - OpenAPI 3.0 specification for Kokoro API endpoints
- `quickstart.md` - Deployment guide and usage examples

**Agent Context Updated**:
- Updated `AGENTS.md` with Python (Kokoro-FastAPI), YAML, Istio, Cilium stack

**Constitution Re-Check**: ✅ PASS
- All HomeCluster GitOps patterns followed
- YAML formatting standards met
- Istio ambient mesh integration planned
- No complexity violations

---

### ⏸️ Phase 2: Task Decomposition (DEFERRED)

**Status**: Not created by `/speckit.plan` - awaiting `/speckit.tasks` command

**Expected Output**: `tasks.md` with granular implementation tasks

---

## Next Steps

1. **Run `/speckit.tasks`** to generate Phase 2 task decomposition
2. **Verify Kokoro-FastAPI image path** at https://github.com/remsky/Kokoro-FastAPI
3. **Create Kubernetes manifests** in `/kubernetes/apps/ai-services/kokoro-api/`
4. **Validate resource limits** after initial deployment and adjust if needed
5. **Test acceptance scenarios** from spec.md User Stories 1-4
