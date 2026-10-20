# Cluster testing

Load and end-to-end smoke testing for the cluster. Everything here is on-demand:
the run templates are plain manifests that live in Git but are deliberately not
part of any Flux Kustomization, so a test only runs when an operator applies it.

## What exists

| Component | Where | What it does |
|---|---|---|
| `testing` namespace | `kubernetes/apps/testing/namespace.yaml` | Holds run objects, scripts, and dashboards. Istio injection is disabled. |
| k6 operator | `kubernetes/operators/k6-operator/` | Reconciles `TestRun` custom resources into k6 initializer, starter, and runner Jobs. |
| k6 runner | `kubernetes/apps/testing/k6/` | `k6-scripts` ConfigMap (`smoke.js`), the `k6-dashboard` ConfigMap, and `runs/smoke-testrun.yaml`. |
| Playwright runner | `kubernetes/apps/testing/playwright/` | `playwright-tests` ConfigMap, `playwright-dashboard` ConfigMap, and two Job templates under `runs/`. |
| Selenium Grid | `kubernetes/apps/selenium/` | Browser pool used by the primary Playwright template. See `kubernetes/apps/selenium/README.md`. |
| Grafana dashboards | Folder `Load Testing` | `k6 Prometheus` (uid `k6-prometheus`) and `Playwright E2E` (uid `playwright-e2e`), provisioned by the Grafana sidecar. |

The primary Playwright template is `runs/playwright-grid.yaml`. It drives Chrome
through the Selenium Grid. `runs/playwright-local.yaml` is the fallback: it runs
Chromium, Firefox, and WebKit inside the Playwright container with no Grid.

## Prerequisites and health checks

Run these before a test session. All four must look healthy.

```bash
kubectl get crd testruns.k6.io
kubectl -n k6-operator get deploy
kubectl -n selenium get pods
kubectl -n testing get cm
```

Expected state:

- The `testruns.k6.io` CRD exists.
- The k6 operator Deployment is Available.
- The Selenium pods are Running and Ready: one hub, one chrome node, one firefox node.
- The `testing` namespace lists `k6-scripts`, `playwright-tests`, `k6-dashboard`, and `playwright-dashboard`.

If a ConfigMap is missing, the `k6` or `playwright` Flux Kustomization has not
reconciled yet. Check with `flux -n flux-system get ks k6 playwright`.

## Run the k6 smoke test

The template is `kubernetes/apps/testing/k6/runs/smoke-testrun.yaml`. A TestRun
has no `condition=complete`, so `kubectl wait --for=condition=complete` will not
work on it. Poll the `.status.stage` field instead. The terminal value is
`finished`.

```bash
kubectl -n testing delete testrun k6-smoke --ignore-not-found
kubectl -n testing apply -f kubernetes/apps/testing/k6/runs/smoke-testrun.yaml

# TestRun has no condition=complete; wait for the stage field instead (final value: finished)
while [ "$(kubectl -n testing get testrun k6-smoke -o jsonpath='{.status.stage}')" != "finished" ]; do
  sleep 3
done
kubectl -n testing get testrun,jobs,pods
kubectl -n testing logs job/k6-smoke-1 --tail=40
```

Observed timings from two consecutive verified runs with the 30 s profile:

| Step | Run 1 | Run 2 |
|---|---|---|
| `apply` to `.status.stage=finished` | 41 s | 41 s |
| Runner Job `k6-smoke-1` duration | 35 s | 35 s |
| Initializer Job `k6-smoke-initializer` duration | 4 s | 4 s |
| Starter Job `k6-smoke-starter` duration | 13 s | 13 s (Complete) |

The stage progresses through `initialization`, `initialized`, `created`,
`started`, `stopped` (when the runner finishes while the operator is still
watching), and finally `finished`. A successful run always ends at `finished`;
`error` is the failure terminal. If a delete is still pending, the idempotent
fallback is:

```bash
kubectl -n testing wait --for=delete testrun/k6-smoke --timeout=120s
```

Then re-apply. Both deletes in the verified runs completed in one second or less,
so the fallback never fired.

If `stage=created` persists for more than 2 minutes while the runner Job is
already `Complete`, the operator missed the short-lived readiness window. Recover
by deleting and re-applying the TestRun; do not wait indefinitely and do not
weaken any policy:

```bash
kubectl -n testing get job k6-smoke-1
kubectl -n testing delete testrun k6-smoke
kubectl -n testing apply -f kubernetes/apps/testing/k6/runs/smoke-testrun.yaml
```

The 30 s profile in this repo makes that race unlikely: the runner now outlives
the operator's 10 s readiness probe by several probe windows (measured twice at
41 s end to end, previously 10 s tests stuck at `created`).

### The starter Job can end in Error on very short tests

The starter Job is the operator's pause helper. On a test that ends almost
immediately it can race the end of the run and finish as `Error` with a log line
like `constant-vus executor 'default' doesn't support pause and resume operations
after its start`. With the 30 s profile in this repo it completed normally in
both verified runs, but treat an occasional starter `Error` as cosmetic.

Check the runner Job, not the starter:

```bash
kubectl -n testing get job k6-smoke-1 -o wide
```

A successful run shows `k6-smoke-1` as `Complete 1/1`, the runner pod exit code 0,
and `.status.stage=finished`. Do not treat the starter Job as a failure signal.

### Change the target

`smoke.js` reads `BASE_URL` and defaults to `https://test.k6.io`. Two options:

1. Edit the default in `kubernetes/apps/testing/k6/app/smoke.js`.
2. Pass an override in the TestRun arguments. Add `-e BASE_URL=https://quickpizza.grafana.com`
   to `spec.arguments`, for example:

```yaml
spec:
  arguments: "-o experimental-prometheus-rw --tag testid=smoke -e BASE_URL=https://quickpizza.grafana.com"
```

Keep the `--tag testid=smoke` argument. The dashboards filter on `testid`.

### Change the load profile

Edit `options` in `kubernetes/apps/testing/k6/app/smoke.js`:

```javascript
export const options = {
  vus: 2,
  duration: '30s',
};
```

The current profile is 2 virtual users for 30 seconds, with a GET to `/` and a
GET to `/contacts.php` per iteration. The 30 s lifetime is deliberate: a 10 s
test could finish before the operator's 10 s readiness probe observed the runner
pod, leaving the TestRun at `stage=created`.

After an edit, commit and push, reconcile the ConfigMap (see
[Adding tests](#adding-tests)), then delete and re-apply the TestRun so the new
script is loaded.

## Run the Playwright suite

### Selenium Grid mode (primary)

This runs the `chromium-grid` project through the Grid hub at
`http://selenium-grid-selenium-hub.selenium.svc.cluster.local:4444`.

```bash
kubectl -n testing delete job playwright-grid --ignore-not-found
kubectl -n testing apply -f kubernetes/apps/testing/playwright/runs/playwright-grid.yaml
kubectl -n testing wait --for=condition=complete job/playwright-grid --timeout=900s
kubectl -n testing logs job/playwright-grid --tail=20
```

Observed timings: the `wait` returned after 14 s, and the Job itself ran for 13 s.
A passing log ends with a `chromium-grid` line and a summary like:

```text
  ✓  1 [chromium-grid] › .../tests/home.spec.ts:6:5 › pushgateway UI is served (2.4s)

  1 passed (5.3s)
Pushed Playwright metrics for suite "home": passed=1 failed=0 flaky=0 skipped=0 duration=5323.992ms
```

If the runner container has not started because the Job still exists, delete it
first. The delete is idempotent thanks to `--ignore-not-found`. The fallback for
a deletion that is still pending is:

```bash
kubectl -n testing wait --for=delete job/playwright-grid --timeout=120s
```

### Bundled browsers (fallback)

This runs all three projects, `chromium`, `firefox`, and `webkit`, inside the
Playwright image with no Grid involved.

```bash
kubectl -n testing delete job playwright-local --ignore-not-found
kubectl -n testing apply -f kubernetes/apps/testing/playwright/runs/playwright-local.yaml
kubectl -n testing wait --for=condition=complete job/playwright-local --timeout=300s
kubectl -n testing logs job/playwright-local --tail=20
```

The template and run were verified with `--timeout=900s` and finished in 12 s
with `3 passed (4.2s)`. The 300 s ceiling above is the documented, generous
value; it was not re-executed at 300 s after the initial verification.

## Dashboards and results

Both dashboards are in the Grafana folder `Load Testing`, provisioned from
ConfigMaps labelled `grafana_dashboard: "1"`.

| Dashboard | uid | Datasource | Queries |
|---|---|---|---|
| `k6 Prometheus` | `k6-prometheus` | `Thanos-NoDedup` (uid `thanos-raw`) | `k6_*` series tagged `testid="smoke"` |
| `Playwright E2E` | `playwright-e2e` | `Prometheus` (uid `prometheus`, deduped) | Pushgateway gauges for `job="playwright-e2e"` |

### Why the k6 dashboard uses a separate datasource

k6 writes metrics with remote-write straight to the Prometheus Service. That
opens a single connection, so the samples from a run land on one Prometheus
replica. Thanos Query runs with `--query.replica-label=prometheus_replica` and
deduplicates replicas by default.

Measured behaviour (task-12, task-21, and F4 evidence):

- During a run, both the default deduped `Prometheus` datasource and `dedup=false`
  return data. Measured at `2026-10-19T23:51:15Z` (epoch `1792453875`):
  `count(k6_http_reqs_total{testid="smoke"})` was `4` on both paths.
- After the run, k6's final flush writes stale markers for the series to the
  connected replica. If that replica is the only copy, an instant query returns
  empty on BOTH paths as soon as the stale marker is the latest sample:
  `dedup=false` does not extend an instant-query window. F4 measured both paths
  empty at `01:07:28Z`, 31 s after the run ended.
- The raw samples remain available to range queries. At `2026-10-19T23:59:59Z`
  a `count_over_time(...[10m])` returned data on both paths.
- Block-backed history returns after Prometheus cuts and uploads a block. With
  `thanos-store` maxTime at `1792454400000` (`2026-10-20T00:00:00Z`), an instant
  query at the `2026-10-19T23:51:40Z` run timestamp (`epoch 1792453900`)
  returned `count(k6_http_reqs_total{testid="smoke"}) = 4` with `dedup=false`.
  The default deduped path returned empty at that exact timestamp because the
  stale marker is the latest sample for the merged replica set; at
  `23:51:15Z`, while real samples were still the newest, both paths returned `4`.

`Thanos-NoDedup` (uid `thanos-raw`) is the same Thanos endpoint with the query
parameter `dedup=false`. It is the deterministic choice for the k6 dashboard
because it avoids replica-selection ambiguity for single-replica remote-write
series: without dedup the query returns the replica that holds the samples
instead of collapsing it against stale markers from the peer replica. It is not a
universal "dedup hides everything" workaround: deduped instant queries still
work while real samples are the newest, and range queries work on both paths.
It is non-default and used only by the k6 dashboard.

The Playwright dashboard is different. Its gauges are scraped from the
Pushgateway by Prometheus, so both replicas hold them and the normal deduped
`Prometheus` datasource works. Leave it on `prometheus`.

### Live window versus history

During a run, the default deduped query and `thanos-raw` (`dedup=false`) both
return the k6 series (measured: count `4` on both at `2026-10-19T23:51:15Z`).
When the run ends, k6's final flush writes stale markers to the replica holding
the series; if that replica is the only copy, instant queries on both paths
return empty immediately once the stale marker is the newest sample. Avoid
treating `dedup=false` as an instant-query extension: it does not add a window.

Raw samples stay queryable with range selectors (for example
`count_over_time(k6_http_reqs_total{testid="smoke"}[10m])`, verified non-empty
at `2026-10-19T23:59:59Z`), and block-backed history returns after Prometheus
cuts and uploads a block (roughly 2 to 3 hours on this cluster). Demonstrated:
with the uploaded block present (`thanos-store` maxTime `1792454400000`), the
`2026-10-19T23:51:40Z` run timestamp (`1792453900`) returns count `4` through
`thanos-raw`; the deduped path returns empty at that instant because dedup
collapses the series against the newer stale marker. Use the k6 dashboard
(`thanos-raw`) for live and just-finished results, and use a range query or wait
for the block-backed history when you need a stable instant answer afterwards.

## Metric contract

| Producer | Metric | Labels | Type |
|---|---|---|---|
| k6 | `k6_http_reqs_total` | `testid="smoke"`, `testrun_name`, `status`, `name` | counter |
| k6 | `k6_http_req_duration_p95` | `testid="smoke"`, `testrun_name` | gauge |
| Playwright | `playwright_tests` | `job="playwright-e2e"`, `suite="home"`, `status` in `passed`, `failed`, `flaky`, `skipped` | gauge |
| Playwright | `playwright_duration_seconds` | `job="playwright-e2e"`, `suite="home"` | gauge |
| Playwright | `playwright_last_run_timestamp_seconds` | `job="playwright-e2e"`, `suite="home"` | gauge |

k6 also emits the usual `k6_*` family, including `http_req_duration`, iterations,
and checks. The dashboard uses the `testid` tag to separate runs.

The Playwright values are gauges, not counters. They are pushed to the same
grouping key, `job="playwright-e2e",suite="home"`, so the most recent run
overwrites the previous values. That means the dashboard shows the last run for
both grid and local modes, while Thanos still retains the time series history.

## Adding tests

### k6

1. Edit `kubernetes/apps/testing/k6/app/smoke.js`. The `k6-scripts` ConfigMap is
   generated by the kustomize `configMapGenerator` in that directory.
2. To add a separate script, add the file to the generator's `files` list and
   create a TestRun under `runs/` that references it through
   `spec.script.configMap.file`.
3. Commit and push to `main`.
4. Reconcile the ConfigMap and re-run:

```bash
flux reconcile source git flux-system
flux reconcile kustomization k6 -n flux-system --with-source
```

Flux variable substitution is disabled on the generated ConfigMap through the
`kustomize.toolkit.fluxcd.io/substitute: disabled` annotation. Keep it that way,
because the script contains no Flux variables and the annotation prevents
accidental expansion of `$` sequences.

Alternatively, wait for the 10 to 30 minute reconcile interval before re-running.

### Playwright

1. Edit or add a spec under `kubernetes/apps/testing/playwright/app/tests/`.
2. Register the file in the `configMapGenerator` in
   `kubernetes/apps/testing/playwright/app/kustomization.yaml`.
3. Add the same file to the `items` list of the `tests` volume in both Job
   templates. The ConfigMap uses `items` because a key cannot contain a slash:
   the key `home.spec.ts` is mapped to the path `tests/home.spec.ts`. Without the
   mapping, `testDir: './tests'` finds nothing.
4. Commit and push, then reconcile and re-run:

```bash
flux reconcile source git flux-system
flux reconcile kustomization playwright -n flux-system --with-source
```

Flux substitution is disabled on `playwright-tests` for the same reason as the
k6 ConfigMap. The annotation keeps the TypeScript and Node file contents
literal, so `$` sequences in the test code are never expanded by Flux.

## Troubleshooting

### Kyverno admission denials

Every operator-created container needs a pinned image tag and resource requests
and limits. The k6 operator generates the initializer, starter, and runner Jobs
from the TestRun, and the initializer gets no resources by default, so an empty
`spec.initializer.resources` is denied by `require-pod-resources`. The templates
in this repo already pin `grafana/k6:2.3.0` and set resources for both the
initializer and the runner.

Check the events:

```bash
kubectl -n testing get events --sort-by=.lastTimestamp | grep -iE 'denied|kyverno|forbidden'
```

An empty result means no policy denials. If a denial appears, fix the workload
manifest. Do not weaken the policies.

### Selenium Grid health

Ask the hub directly:

```bash
kubectl -n selenium exec deploy/selenium-grid-selenium-hub -- curl -s http://localhost:4444/status
```

The response reports `"ready": true` when the hub is up, and lists the chrome
and firefox nodes. If a Grid session cannot be created in a Playwright run,
check this endpoint first, then confirm the `SELENIUM_REMOTE_URL` in
`runs/playwright-grid.yaml` matches the hub Service.

### Pushgateway metrics

Read the metrics from a throwaway pod, which is removed on exit:

```bash
kubectl -n monitoring run pw-rerun-qa --rm -i --restart=Never --image=curlimages/curl:8.16.0 -- \
  sh -c 'curl -sS http://pushgateway:9091/metrics | grep -E "^playwright_(tests|duration_seconds|last_run_timestamp_seconds)"'
```

A successful run shows `playwright_tests` with one line per status, plus the
duration and last-run gauges. An empty result means the push did not happen,
so read the Job logs for the `push-metrics.mjs` output.

### Grafana access

Basic authentication is disabled on this cluster; Grafana is OAuth-only, so
`curl -u admin:password` against the API returns 401 by design. Use the
sidecar and database evidence instead. Dashboards are sidecar-loaded into
Grafana's runtime folder, not the Helm chart's file-provider path:

```bash
kubectl -n monitoring exec deploy/grafana -- sh -c '
  ls "/tmp/dashboards/Load Testing/"
  grep -c thanos-raw "/tmp/dashboards/Load Testing/k6-prometheus.json"
  grep -a k6-prometheus /var/lib/grafana/grafana.db >/dev/null && echo present
'
```

`k6-prometheus.json` and `playwright.json` should both be listed, the
`thanos-raw` count should be non-zero (the k6 dashboard has no unresolved
datasource template tokens left), and `present` confirms the dashboard is
registered in the Grafana database. The old Helm chart file-provider directory
under `/var/lib/grafana/dashboards/` is intentionally empty; do not look there.

## Scheduling (not implemented in this repo)

The runs are on-demand today. There is no CronJob, ServiceAccount, or RBAC for
automated runs, and adding one was out of scope for this work.

The documented upstream pattern is a CronJob that runs `kubectl delete` followed
by `kubectl apply` on a TestRun, using a namespaced ServiceAccount bound to a
Role that allows `get`, `create`, and `delete` on `testruns.k6.io` in `testing`.

Reference: [k6 scheduling tests](https://grafana.com/docs/k6/latest/set-up/set-up-distributed-k6/usage/scheduling-tests/)

If this is implemented later, keep the following in mind:

- The CronJob needs its own image with `kubectl`, a pinned tag, and resource
  requests and limits to pass Kyverno.
- Delete and re-apply reuse the same object name, so concurrent runs would race.
- A short test still leaves the starter Job in `Error`; alert on the runner Job
  and on `.status.stage`, not on the starter.
