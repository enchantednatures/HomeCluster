# Selenium Grid

A small, always-on Selenium Grid used as a browser backend for the cluster's
Playwright smoke test. It is not a general-purpose browser farm; the pool is
sized for light, single-test use.

The component is deployed from `kubernetes/apps/selenium/selenium-grid/` with
chart `selenium-grid` version `0.62.0` from the `selenium` HelmRepository.

## Topology

| Component | Replicas | Image source | Purpose |
|---|---|---|---|
| Hub | 1 | Chart default | Router and session endpoint, Service `selenium-grid-selenium-hub` on port 4444. |
| Chrome node | 1 | Chart default, no `latest` tag | Provides Chrome sessions. |
| Firefox node | 1 | Chart default, no `latest` tag | Provides Firefox sessions. |

The following chart features are explicitly disabled in the HelmRelease:

- `edgeNode.enabled: false`
- `videoRecorder.enabled: false`
- `ingress.enabled: false` and `ingress.enableWithController: false`
- `autoscaling.enabled: false` and `autoscaling.enableWithExistingKEDA: false`
- The chart's bundled monitoring stack (`monitoring.enabled: false`), while
  keeping the hub's built-in exporter enabled through
  `monitoring.enabledWithExistingAgent: true`.

There is no ingress, no KEDA scaling, and no video recording. The hub Service
exposes 4444, 4442, 4443, and 9615.

## Resource footprint

| Component | CPU request | Memory request | Memory limit |
|---|---|---|---|
| Hub | 250m | 512Mi | 1Gi |
| Chrome node | 500m | 1Gi | 2Gi |
| Firefox node | 500m | 1Gi | 2Gi |
| **Total** | **1.25 CPU** | **2.5GiB** | **5GiB** |

CPU limits are left unset. All three pods must carry requests and memory limits
to pass the Kyverno resource policies.

## Metrics

The chart enables the hub's Prometheus exporter on port 9615. A standalone
ServiceMonitor, `kubernetes/apps/selenium/selenium-grid/app/servicemonitor.yaml`,
scrapes it:

| Field | Value |
|---|---|
| ServiceMonitor | `selenium-grid` in namespace `selenium` |
| Selector | `app: selenium-grid-selenium-hub`, `app.kubernetes.io/instance: selenium-grid` |
| Port | `tcp-metrics` (9615) |
| Path | `/metrics` |
| Interval | 30s |
| Scrape timeout | 10s |

The chart's own `serviceMonitor`, `podMonitor`, and Grafana dashboard values are
disabled because this repo supplies the ServiceMonitor and dashboards itself.

## Health check

```bash
kubectl -n selenium get pods
kubectl -n selenium exec deploy/selenium-grid-selenium-hub -- curl -s http://localhost:4444/status
```

`get pods` should show the hub, chrome node, and firefox node Running and Ready.
The `/status` response reports `"ready": true` and lists the registered browser
nodes (chrome and firefox in this deployment).

## Playwright compatibility caveat

Selenium Grid speaks WebDriver. Playwright speaks its own protocol and can use a
Grid only through its experimental Selenium integration:

- Only Chromium-based browsers work through the Grid, meaning Chrome and,
  upstream, Edge.
- Point Playwright at the Grid by setting `SELENIUM_REMOTE_URL` to
  `http://selenium-grid-selenium-hub.selenium.svc.cluster.local:4444`. The
  `chromium-grid` project in `playwright.config.ts` is enabled only when that
  variable is set.
- Firefox and WebKit cannot go through this Grid. Playwright's Firefox and
  WebKit builds are not WebDriver-compatible with the Grid nodes.

For real cross-browser coverage, use the bundled-browser template
`kubernetes/apps/testing/playwright/runs/playwright-local.yaml`. It runs
Chromium, Firefox, and WebKit inside the Playwright container and does not touch
the Grid. The Grid template stays the primary path because it exercises a
separate, long-lived browser service; the local template is the fallback.
