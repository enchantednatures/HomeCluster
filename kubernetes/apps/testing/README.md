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

Observed timings from the verified re-run:

| Step | Observed |
|---|---|
| `apply` to `.status.stage=finished` | 19 s |
| Runner Job `k6-smoke-1` duration | 15 s |
| Initializer Job `k6-smoke-initializer` duration | 4 s |

The stage progresses through `initialization`, `created`, `started`, and finally
`finished`. If a delete is still pending, the idempotent fallback is:

```bash
kubectl -n testing wait --for=delete testrun/k6-smoke --timeout=120s
```

Then re-apply. Both deletes in the verified runs completed in one second or less,
so the fallback never fired.

### The starter Job can end in Error

On a short test, `job/k6-smoke-starter` may finish as `Error` with a log line like
`constant-vus executor 'default' doesn't support pause and resume operations
after its start`. That Job is the operator's pause helper, and it races a 10 s
test that has already ended. It is cosmetic and expected.

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
  duration: '10s',
};
```

The current profile is 2 virtual users for 10 seconds, with a GET to `/` and a
GET to `/contacts.php` per iteration. After an edit, commit and push, reconcile
the ConfigMap (see [Adding tests](#adding-tests)), then delete and re-apply the
TestRun so the new script is loaded.

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

### Why k6 uses a separate datasource

k6 writes metrics with remote-write straight to the Prometheus Service. That
opens a single connection, so all samples land on one Prometheus replica. Thanos
Query runs with `--query.replica-label=prometheus_replica`, and its default
replica dedup returns an empty result for series that exist on only one replica.

`Thanos-NoDedup` (uid `thanos-raw`) is the same Thanos endpoint with the custom
query parameter `dedup=false`. It is non-default and used only by the k6
dashboard. Do not point the k6 dashboard back at the deduped `Prometheus`
datasource. Measured during verification: the default query returned an empty
vector while `dedup=false` returned the expected count.

The Playwright dashboard is different. Its gauges are scraped from the
Pushgateway by Prometheus, so both replicas hold them and the normal deduped
`Prometheus` datasource works. Leave it on `prometheus`.

### Live window versus history

k6 series are visible during and immediately after a run, through the Prometheus
head and the 5 minute staleness lookback. They become reliably queryable as
history after Prometheus cuts and uploads a block. The measured block cadence on
this cluster is roughly 2 to 3 hours. During verification, the run was at 23:51Z
and the newest block on disk ended at 22:00Z, which is consistent with that
cadence. A query for a just-finished run can therefore be empty on the deduped
path until a block exists, while `dedup=false` and the live head still answer.

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
provisioning and file evidence instead:

```bash
kubectl -n monitoring exec deploy/grafana -- sh -c 'ls /var/lib/grafana/dashboards/loadtesting/ && grep -a k6-prometheus /var/lib/grafana/grafana.db >/dev/null && echo present'
```

`k6-prometheus.json` and `playwright.json` should be present, and `present`
confirms the dashboard is registered in the Grafana database.

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
