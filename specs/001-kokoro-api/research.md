# Research: Kokoro Text-to-Speech API Integration

**Feature**: 001-kokoro-api  
**Date**: 2026-01-20  
**Phase**: 0 - Outline & Research

## Research Tasks

### 1. Storage Volume Type Selection

**Decision**: Use `emptyDir` ephemeral volume (no PersistentVolumeClaim required)

**Rationale**:
- Audio files consumed immediately (per spec assumptions line 140)
- No long-term storage requirement
- Reduces infrastructure complexity (no PVC/PV management)
- Sufficient for temporary audio generation output
- Aligns with "no caching" clarification

**Alternatives Considered**:
- **PersistentVolumeClaim (OpenEBS/Rook-Ceph)**: Rejected - adds unnecessary complexity for ephemeral data
- **MinIO external storage**: Rejected - overkill for temporary files that are immediately downloaded

**Implementation**: Add `emptyDir` volume in Deployment spec, mount at `/tmp/audio` or similar path

---

### 2. Automated Testing Approach

**Decision**: Use `task kubernetes:kubeconform` for schema validation + manual smoke tests post-deployment

**Rationale**:
- HomeCluster already uses `task kubernetes:kubeconform` (AGENTS.md line 13)
- Kokoro-FastAPI testing handled by upstream container
- No custom application code to test (pure infrastructure deployment)
- Manual validation sufficient for MVP (curl test to verify audio generation)

**Alternatives Considered**:
- **pytest integration tests**: Rejected - no custom Python code to test
- **Helm chart tests**: Rejected - if using raw manifests, not applicable
- **Automated smoke tests in CI**: Deferred - can add later if needed

**Implementation**: Run `task kubernetes:kubeconform` before commit, validate with manual curl after `task flux:apply path=<namespace>/kokoro-api`

---

### 3. CPU/Memory Resource Requests and Limits

**Decision**: Research Kokoro-FastAPI upstream documentation and model requirements

**Research Needed**:
1. Check https://github.com/remsky/Kokoro-FastAPI README for resource requirements
2. Investigate Kokoro TTS model size and inference resource needs
3. Review typical TTS workload patterns (CPU vs GPU, memory footprint)

**Preliminary Recommendations** (to be validated):
- **Requests**: `cpu: 500m, memory: 1Gi` (conservative starting point)
- **Limits**: `cpu: 2000m, memory: 4Gi` (allow burst for concurrent requests)
- **GPU**: None required unless Kokoro-FastAPI specifically needs it (check repo)

**Validation Strategy**: Deploy with conservative limits, monitor resource usage via Prometheus, adjust based on actual workload

---

### 4. Container Registry Strategy

**Decision**: Use public GitHub Container Registry (ghcr.io) for Kokoro-FastAPI image

**Rationale**:
- Kokoro-FastAPI likely published to ghcr.io/remsky/kokoro-fastapi (verify)
- No need for internal registry if upstream image available
- Simplifies deployment (no image pull secrets required)
- Aligns with "no secrets needed" clarification

**Alternatives Considered**:
- **Internal Harbor/Registry**: Rejected - unnecessary unless image customization required
- **Docker Hub**: Possible fallback if ghcr.io not available

**Implementation**: Reference image directly in Deployment/HelmRelease: `image: ghcr.io/remsky/kokoro-fastapi:<version>`

**Action Required**: Verify exact image path and tag from https://github.com/remsky/Kokoro-FastAPI

---

### 5. Ingress Pattern: Istio Gateway vs Cloudflare Tunnel

**Decision**: Use Istio Gateway + VirtualService (no Cloudflare Tunnel unless external access required)

**Rationale**:
- Spec doesn't specify external access requirement (may be internal-only service)
- Istio Gateway provides internal cluster ingress with retry logic (needed per clarifications)
- Cloudflare Tunnel only needed if exposing to internet (AGENTS.md line 8: "Ingress via Cloudflare Tunnels")
- VirtualService handles retry policy: exponential backoff, 3 attempts (clarification #3)

**Alternatives Considered**:
- **Cloudflare Tunnel**: Use if external access needed (defer until requirement confirmed)
- **Kubernetes Ingress**: Rejected - Istio VirtualService provides richer traffic management

**Implementation**:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: kokoro-api
spec:
  hosts:
  - kokoro-api.<namespace>.svc.cluster.local
  http:
  - retries:
      attempts: 3
      perTryTimeout: 30s
      retryOn: 5xx,reset,connect-failure,refused-stream
    route:
    - destination:
        host: kokoro-api
        port:
          number: 8000
```

---

### 6. Istio VirtualService Retry Policy Parameters

**Decision**: Configure retry with exponential backoff, 3 attempts, 30s per-try timeout

**Parameters**:
- **Attempts**: 3 (from clarification #3: "Retry with exponential backoff (3 attempts)")
- **Per-Try Timeout**: 30s (from edge cases: "Apply request timeout (30s default)")
- **Retry On**: `5xx,reset,connect-failure,refused-stream` (standard transient failures)
- **Backoff**: Istio default exponential backoff (25ms base, 250ms max jitter)

**Rationale**:
- Aligns with clarifications and edge case resolutions
- Handles pod restarts, network hiccups, temporary unavailability
- Per-try timeout prevents indefinite hangs
- Standard Istio retry conditions for service mesh

**Implementation**: Add to VirtualService spec (see above)

---

### 7. Namespace Selection

**Decision**: Create new `ai-services` namespace

**Rationale**:
- Logical grouping for AI/ML services (Kokoro TTS, future models)
- Separates from general `default` namespace
- Not media-specific enough for `media` namespace (if exists)
- Allows namespace-level resource quotas and policies

**Alternatives Considered**:
- **default**: Rejected - poor organization, no logical grouping
- **media**: Possible, but TTS is broader than media playback
- **kokoro**: Rejected - too specific, limits future AI service additions

**Implementation**: Create `/kubernetes/apps/ai-services/kokoro-api/namespace.yaml`

---

## Summary of Decisions

| Unknown | Resolution | Confidence |
|---------|------------|------------|
| Storage type | `emptyDir` ephemeral volume | High - aligns with spec assumptions |
| Testing approach | kubeconform + manual smoke tests | High - standard HomeCluster pattern |
| CPU/Memory limits | 500m/1Gi requests, 2000m/4Gi limits | Medium - needs validation from upstream |
| Container registry | ghcr.io public registry | High - verify image path |
| Ingress pattern | Istio Gateway + VirtualService (internal) | High - retry logic required |
| Retry policy params | 3 attempts, 30s timeout, exponential backoff | High - from clarifications |
| Namespace | `ai-services` | Medium - organizational preference |

**Next Phase**: Phase 1 - Generate data-model.md, contracts/, quickstart.md
