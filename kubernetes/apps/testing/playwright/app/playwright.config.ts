import { defineConfig, devices } from '@playwright/test';

const usingSeleniumGrid = Boolean(process.env.SELENIUM_REMOTE_URL);

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  workers: usingSeleniumGrid ? 2 : undefined,
  reporter: [
    ['list'],
    ['json', { outputFile: process.env.PLAYWRIGHT_JSON_OUTPUT_NAME ?? 'results.json' }],
  ],
  use: {
    trace: 'retain-on-failure',
  },
  projects: usingSeleniumGrid
    ? [
        {
          name: 'chromium-grid',
          use: { ...devices['Desktop Chrome'] },
        },
      ]
    : [
        {
          name: 'chromium',
          use: { ...devices['Desktop Chrome'] },
        },
        {
          name: 'firefox',
          use: { ...devices['Desktop Firefox'] },
        },
        {
          name: 'webkit',
          use: { ...devices['Desktop Safari'] },
        },
      ],
});
