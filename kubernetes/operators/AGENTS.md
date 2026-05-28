# AGENTS.md - Operators Layer

## Overview

Kubernetes operators and CRDs. Deployed after core + infra are ready. Each operator typically has `operator/` (CRDs/operator) and app/cluster subdirs.

## Structure

```
kubernetes/operators/
├── actions-runner-controller/  # GitHub Actions runners
├── arangodb/                   # ArangoDB operator
├── cnpg-system/                # CloudNative-PG
├── dragonflydb/                # DragonflyDB (operator + cluster)
├── elastic/                    # ECK (operator + search + kibana)
├── flagger/                    # Canary/blue-green deployments
├── flink/                      # Apache Flink operator
├── kubevirt/                   # KubeVirt + CDI
├── medik8s/                    # Node health remediation
├── rabbitmq-operator/          # RabbitMQ cluster operator
├── redpanda/                   # Redpanda (operator + console)
├── rook-ceph/                  # Ceph storage (operator + cluster)
├── schema-registry/            # Confluent Schema Registry
└── volsync/                    # Volume replication
```

## Where to Look

| Task | Location |
|------|----------|
| Add PostgreSQL cluster | `cnpg-system/cloudnative-pg/` or app `db/` |
| Add Redis/Dragonfly cache | `dragonflydb/cluster/` or app `dragonfly/` |
| Ceph storage config | `rook-ceph/cluster/app/` |
| Kafka clusters | `operators/` (Strimzi) or `apps/kafka/` |
| Add operator | Create `<name>/operator/` + app subdirs |

## Conventions

- Operator HelmReleases in `operator/` subdir
- CRD-based apps in separate subdirs (e.g., `cluster/`, `search/`, `kibana/`)
- Apps reference operators via `dependsOn` in their `ks.yaml`
- Use `db/` and `dragonfly/` inside app dirs for per-app resources

## Anti-Patterns

- Never deploy operator CRDs before the operator is ready
- Do not skip `dependsOn` to operators in app `ks.yaml`
