# Data Model: Kokoro Text-to-Speech API Integration

**Feature**: 001-kokoro-api  
**Date**: 2026-01-20  
**Phase**: 1 - Design & Contracts

## Overview

This feature is an infrastructure deployment with no custom application code. The data model describes the **request/response payloads** handled by the Kokoro-FastAPI container and the **Kubernetes resource definitions** deployed to the cluster.

---

## API Data Model (Kokoro-FastAPI Contracts)

### Entity: TextToSpeechRequest

**Description**: HTTP POST request payload for text-to-speech conversion

**Fields**:

| Field | Type | Required | Validation | Description |
|-------|------|----------|------------|-------------|
| `text` | string | Yes | Non-empty, <1000 words (assumption) | Input text to synthesize |
| `voice_id` | string | No | Valid voice ID from Kokoro | Voice identifier (default if not specified) |
| `language` | string | No | ISO 639-1 code (e.g., "en", "ja") | Language code (default: "en") |
| `speaking_rate` | float | No | 0.5 - 2.0 | Speech speed multiplier (default: 1.0) |
| `output_format` | string | No | Enum: "mp3", "wav", "ogg" | Audio format (default: "mp3") |

**Validation Rules**:
- `text` must not be empty or whitespace-only (FR-003)
- `text` length limit enforced by container (check upstream docs for exact limit)
- `voice_id` must exist in Kokoro's voice library (return 400 if invalid)
- `language` + `voice_id` combination must be supported (return 400 if incompatible)
- `speaking_rate` outside range returns 400 with error message
- `output_format` must be one of supported formats (FR-002)

**Example**:
```json
{
  "text": "Hello, this is a test of the Kokoro text-to-speech system.",
  "voice_id": "af_bella",
  "language": "en",
  "speaking_rate": 1.0,
  "output_format": "mp3"
}
```

---

### Entity: TextToSpeechResponse

**Description**: HTTP response containing synthesized audio

**Success Response (200 OK)**:

| Field | Type | Description |
|-------|------|-------------|
| `Content-Type` | Header | `audio/mpeg`, `audio/wav`, or `audio/ogg` |
| `Content-Length` | Header | Audio file size in bytes |
| Body | Binary | Audio file content |

**Error Response (4xx/5xx)**:

| Field | Type | Description |
|-------|------|-------------|
| `error` | string | Error type (e.g., "ValidationError", "UnsupportedVoice") |
| `message` | string | Human-readable error description |
| `details` | object | Optional additional error context |

**Example Error**:
```json
{
  "error": "ValidationError",
  "message": "Text input cannot be empty or whitespace-only",
  "details": {
    "field": "text",
    "received": "   "
  }
}
```

---

### Entity: BatchTextToSpeechRequest (P3 - Future)

**Description**: Batch processing of multiple text segments (User Story 3)

**Fields**:

| Field | Type | Required | Validation | Description |
|-------|------|----------|------------|-------------|
| `items` | array[TextToSpeechRequest] | Yes | 1-100 items | Array of individual requests |
| `concatenate` | boolean | No | Default: false | Whether to merge audio outputs |

**Response**: Array of results or single concatenated audio file

---

## Kubernetes Resource Model

### Resource: Deployment (kokoro-api)

**Description**: Kubernetes Deployment for Kokoro-FastAPI container

**Key Specifications**:

| Field | Value | Rationale |
|-------|-------|-----------|
| `replicas` | 1 (initial) | Start with single replica, scale based on load |
| `image` | `ghcr.io/remsky/kokoro-fastapi:<version>` | Public container registry (research.md decision #4) |
| `resources.requests.cpu` | `500m` | Conservative baseline (research.md decision #3) |
| `resources.requests.memory` | `1Gi` | Baseline for model inference |
| `resources.limits.cpu` | `2000m` | Allow burst for concurrent requests |
| `resources.limits.memory` | `4Gi` | Prevent OOM during peak load |
| `volumeMounts[0].name` | `audio-output` | Temporary audio file storage |
| `volumeMounts[0].mountPath` | `/tmp/audio` | Mount path for audio generation |
| `volumes[0].emptyDir` | `{}` | Ephemeral volume (research.md decision #1) |

**Lifecycle**:
- **Readiness Probe**: HTTP GET `/health` or `/` (verify endpoint from upstream)
- **Liveness Probe**: HTTP GET `/health` (restart if unhealthy)
- **Restart Policy**: `Always` (standard pod restart on failure)

---

### Resource: Service (kokoro-api)

**Description**: ClusterIP Service for internal routing

**Key Specifications**:

| Field | Value | Rationale |
|-------|-------|-----------|
| `type` | `ClusterIP` | Internal cluster access only (unless external access needed) |
| `ports[0].port` | `8000` | Kokoro-FastAPI default port (verify from upstream) |
| `ports[0].targetPort` | `8000` | Container port |
| `ports[0].name` | `http` | Named port for Istio VirtualService |
| `selector.app` | `kokoro-api` | Match Deployment labels |

**FQDN**: `kokoro-api.ai-services.svc.cluster.local:8000` (for service mesh discovery)

---

### Resource: VirtualService (kokoro-api)

**Description**: Istio VirtualService for retry policy and traffic management

**Key Specifications**:

| Field | Value | Rationale |
|-------|-------|-----------|
| `hosts` | `["kokoro-api.ai-services.svc.cluster.local"]` | Internal FQDN |
| `http.retries.attempts` | `3` | From clarification #3 |
| `http.retries.perTryTimeout` | `30s` | From edge case resolution |
| `http.retries.retryOn` | `5xx,reset,connect-failure,refused-stream` | Transient failure handling |
| `http.timeout` | `90s` | Overall request timeout (3 × 30s) |
| `http.route[0].destination.host` | `kokoro-api` | Service name |
| `http.route[0].destination.port.number` | `8000` | Service port |

**Exponential Backoff**: Istio default (25ms base, 250ms max jitter) - no custom configuration needed

---

### Resource: Namespace (ai-services)

**Description**: Namespace for AI/ML services

**Annotations**:
- `istio-injection: enabled` (if using sidecar mode - check if ambient mesh applies differently)

**Labels**:
- `name: ai-services`
- `app.kubernetes.io/part-of: homecluster`

---

## State Transitions

### Request Processing Lifecycle

```
[Client] → HTTP POST /synthesize
    ↓
[Istio VirtualService] → Retry logic applied
    ↓
[Service] → Route to pod
    ↓
[Kokoro-FastAPI Pod] → Validate request
    ↓
  ┌─────┴──────┐
  │            │
[Valid]    [Invalid]
  │            │
  ↓            ↓
Generate    Return 400
Audio       + error
  ↓
Write to
/tmp/audio
  ↓
Return 200
+ audio binary
  ↓
[Client receives audio]
```

**Retry Trigger Points**:
- Pod not ready → Retry (up to 3 attempts)
- 5xx error → Retry with backoff
- Network failure → Retry
- Timeout (>30s) → Retry once (edge case resolution)
- After 3 failed attempts → Return 503 to client

---

## Data Volume Estimates

**Per Request**:
- Input: ~1KB JSON payload (avg 200-word text)
- Output: ~50KB MP3 audio (1-2 minutes speech)
- Temporary disk usage: 50KB per concurrent request (cleaned after response)

**Concurrent Load (10 requests)**:
- Memory: ~500KB ephemeral storage
- Negligible impact given `emptyDir` backed by node storage

**No Persistence**: All data ephemeral, no database or long-term storage required

---

## Validation Summary

| Requirement | Validation Strategy | Implementation |
|-------------|-------------------|----------------|
| FR-001 | Accept text, return audio | Proxy to Kokoro-FastAPI container |
| FR-002 | Multiple formats | Pass `output_format` param |
| FR-003 | Input validation | Container handles (verify edge cases) |
| FR-004 | Voice customization | Pass `voice_id`, `language`, `speaking_rate` |
| FR-005 | Error handling + retry | Istio VirtualService retry policy |
| FR-006 | Batch processing (P3) | Deferred - extend API contract later |

**Next Phase**: Generate API contracts (OpenAPI spec) and quickstart guide
