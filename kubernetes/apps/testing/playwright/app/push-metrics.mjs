import { readFile } from 'node:fs/promises';

const reportPath = process.env.PLAYWRIGHT_JSON_OUTPUT_NAME ?? 'results.json';
const suite = process.env.SUITE ?? 'e2e';
const pushgatewayUrl = (
  process.env.PUSHGATEWAY_URL ??
  'http://pushgateway.monitoring.svc.cluster.local:9091'
).replace(/\/+$/, '');

const escapeLabel = (value) =>
  String(value)
    .replace(/\\/g, '\\\\')
    .replace(/\n/g, '\\n')
    .replace(/"/g, '\\"');

const report = JSON.parse(await readFile(reportPath, 'utf8'));
const stats = report.stats ?? {};

const expected = Number(stats.expected ?? 0);
const unexpected = Number(stats.unexpected ?? 0);
const flaky = Number(stats.flaky ?? 0);
const skipped = Number(stats.skipped ?? 0);
const durationMs = Number(stats.duration ?? 0);

const labels = `suite="${escapeLabel(suite)}"`;
const body = [
  `playwright_tests{${labels},status="passed"} ${expected}`,
  `playwright_tests{${labels},status="failed"} ${unexpected}`,
  `playwright_tests{${labels},status="flaky"} ${flaky}`,
  `playwright_tests{${labels},status="skipped"} ${skipped}`,
  `playwright_duration_seconds{${labels}} ${durationMs / 1000}`,
  `playwright_last_run_timestamp_seconds{${labels}} ${Math.floor(Date.now() / 1000)}`,
  '',
].join('\n');

try {
  const response = await fetch(`${pushgatewayUrl}/metrics/job/playwright-e2e`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain; version=0.0.4' },
    body,
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`HTTP ${response.status}: ${detail}`);
  }

  console.log(
    `Pushed Playwright metrics for suite "${suite}": passed=${expected} failed=${unexpected} flaky=${flaky} skipped=${skipped} duration=${durationMs}ms`,
  );
} catch (error) {
  console.error(`Failed to push Playwright metrics to ${pushgatewayUrl}: ${error.message}`);
  process.exit(1);
}
