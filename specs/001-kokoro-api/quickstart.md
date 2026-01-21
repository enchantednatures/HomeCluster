# Quickstart: Kokoro Text-to-Speech API

**Feature**: 001-kokoro-api  
**Last Updated**: 2026-01-20

## Prerequisites

- HomeCluster Talos Kubernetes environment (Istio + Cilium + FluxCD)
- `kubectl` configured for cluster access
- `task` CLI tool (Taskfile.yml tasks)
- Git branch `001-kokoro-api` checked out

## Deployment Steps

### 1. Verify Branch and Paths

```bash
# Confirm you're on the feature branch
git branch --show-current
# Expected: 001-kokoro-api

# Check namespace exists (or will be created)
kubectl get namespace ai-services
# If not exists: will be created by manifest
```

### 2. Validate Manifests

Before committing, validate all Kubernetes manifests:

```bash
# Template, encrypt secrets (none needed for Kokoro), and validate
task configure

# Specific kubeconform validation
task kubernetes:kubeconform
```

Expected output: All manifests pass schema validation with no errors.

### 3. Commit and Push (GitOps Workflow)

```bash
# Stage Kubernetes manifest files
git add kubernetes/apps/ai-services/kokoro-api/

# Commit with descriptive message
git commit -m "Add Kokoro text-to-speech service deployment

- Deploy Kokoro-FastAPI container to ai-services namespace
- Configure Istio VirtualService with 3-attempt retry policy
- Set resource limits: 500m/1Gi requests, 2000m/4Gi limits
- Use emptyDir for temporary audio output storage"

# Push to trigger FluxCD reconciliation
git push origin 001-kokoro-api
```

### 4. Force Flux Reconciliation

```bash
# Trigger immediate Flux sync (instead of waiting for interval)
task flux:reconcile

# Or apply specific app
task flux:apply path=ai-services/kokoro-api
```

### 5. Verify Deployment

```bash
# Check pod status
kubectl get pods -n ai-services -l app=kokoro-api

# Expected output:
# NAME                          READY   STATUS    RESTARTS   AGE
# kokoro-api-xxxxxxxxxx-xxxxx   1/1     Running   0          2m

# Check service
kubectl get svc -n ai-services kokoro-api

# Check VirtualService
kubectl get virtualservice -n ai-services kokoro-api
```

### 6. Test the Service (Smoke Test)

```bash
# Port-forward for local testing
kubectl port-forward -n ai-services svc/kokoro-api 8000:8000

# In another terminal, test basic synthesis
curl -X POST http://localhost:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Hello from HomeCluster Kokoro text-to-speech service",
    "output_format": "mp3"
  }' \
  --output test-audio.mp3

# Verify audio file created
ls -lh test-audio.mp3
# Expected: File size ~50KB

# Play audio (if mpg123 installed)
mpg123 test-audio.mp3
```

### 7. Monitor Logs

```bash
# View Kokoro-FastAPI container logs
kubectl logs -n ai-services -l app=kokoro-api --tail=50 -f

# Check for errors or warnings
kubectl logs -n ai-services -l app=kokoro-api | grep -i error
```

---

## Usage Examples

### Basic Text-to-Speech

```bash
curl -X POST http://kokoro-api.ai-services.svc.cluster.local:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "The quick brown fox jumps over the lazy dog.",
    "output_format": "mp3"
  }' \
  --output output.mp3
```

### Customized Voice and Speed

```bash
curl -X POST http://kokoro-api.ai-services.svc.cluster.local:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "This is a test with a custom voice and faster speaking rate.",
    "voice_id": "af_bella",
    "language": "en",
    "speaking_rate": 1.5,
    "output_format": "wav"
  }' \
  --output custom-voice.wav
```

### WAV Format Output

```bash
curl -X POST http://kokoro-api.ai-services.svc.cluster.local:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "This is a WAV format test.",
    "output_format": "wav"
  }' \
  --output test.wav
```

### Error Handling Test (Empty Text)

```bash
curl -X POST http://kokoro-api.ai-services.svc.cluster.local:8000/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "   ",
    "output_format": "mp3"
  }'

# Expected response:
# {
#   "error": "ValidationError",
#   "message": "Text input cannot be empty or whitespace-only",
#   "details": { "field": "text", "received": "   " }
# }
```

---

## Troubleshooting

### Pod Not Starting

```bash
# Check pod events
kubectl describe pod -n ai-services -l app=kokoro-api

# Common issues:
# - Image pull failure: Check container registry access
# - Resource constraints: Verify node has sufficient CPU/memory
# - Volume mount issues: Check emptyDir configuration
```

### 503 Service Unavailable Errors

```bash
# Check Istio VirtualService retry configuration
kubectl get virtualservice -n ai-services kokoro-api -o yaml

# Verify pod readiness
kubectl get pods -n ai-services -l app=kokoro-api

# Check if pod is in CrashLoopBackOff
kubectl logs -n ai-services -l app=kokoro-api --previous
```

### Audio Generation Slow (>5 seconds)

```bash
# Check resource usage
kubectl top pod -n ai-services -l app=kokoro-api

# If CPU/memory saturated, increase limits:
# Edit deployment.yaml resource limits and re-apply
```

### Retry Logic Not Working

```bash
# Verify Istio ambient mesh is enabled
kubectl get namespace ai-services -o yaml | grep istio

# Check VirtualService applied correctly
kubectl get virtualservice -n ai-services kokoro-api -o yaml

# Test retry with temporary pod failure:
# (Scale down to 0, make request, scale back up)
kubectl scale deployment kokoro-api -n ai-services --replicas=0
# Make request → should see retry attempts in logs
kubectl scale deployment kokoro-api -n ai-services --replicas=1
```

---

## Monitoring and Metrics

### Check Resource Usage

```bash
# View resource metrics
task kubernetes:resources

# Specific pod metrics
kubectl top pod -n ai-services -l app=kokoro-api
```

### Grafana Dashboard (Optional)

If custom metrics are added later (currently out-of-scope per FR-007):

1. Navigate to Grafana: `https://grafana.${SECRET_DOMAIN}`
2. Create dashboard for Kokoro service metrics
3. Monitor: request count, latency, error rate, resource usage

---

## Next Steps

1. **Test User Stories**: Validate acceptance scenarios from [spec.md](./spec.md)
   - User Story 1 (P1): Basic text-to-speech ✅ (covered above)
   - User Story 2 (P2): Voice customization ✅ (covered above)
   - User Story 3 (P3): Batch processing (future enhancement)
   - User Story 4 (P3): Usage monitoring (future enhancement)

2. **Performance Testing**: Load test with 10 concurrent requests (SC-003)
   ```bash
   # Use siege, ab, or k6 for load testing
   siege -c 10 -r 5 -H "Content-Type: application/json" \
     --json-file=request.json \
     http://kokoro-api.ai-services.svc.cluster.local:8000/synthesize
   ```

3. **External Access** (if needed): Configure Cloudflare Tunnel or Istio Gateway for public ingress

4. **Documentation**: Update main repository README or docs with Kokoro service availability

---

## Reference

- **OpenAPI Contract**: [contracts/openapi.yaml](./contracts/openapi.yaml)
- **Data Model**: [data-model.md](./data-model.md)
- **Research Decisions**: [research.md](./research.md)
- **Upstream Repository**: https://github.com/remsky/Kokoro-FastAPI
- **Task Commands**: See main `Taskfile.yml` in repository root
