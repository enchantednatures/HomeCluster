import { expect, test } from '@playwright/test';

const BASE_URL =
  process.env.BASE_URL ?? 'http://immich-server.immich.svc.cluster.local:2283';

test('home page loads the Immich login form', async ({ page }) => {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });

  await expect(page).toHaveTitle(/Immich/i);
  await expect(page.locator('input[type="email"]')).toBeVisible();
});
