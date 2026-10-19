import { expect, test } from '@playwright/test';

const BASE_URL =
  process.env.BASE_URL ?? 'http://pushgateway.monitoring.svc.cluster.local:9091';

test('pushgateway UI is served', async ({ page }) => {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });

  await expect(page).toHaveTitle(/Prometheus Pushgateway/i);
  await expect(page.getByRole('link', { name: /Pushgateway/i })).toBeVisible();
});
