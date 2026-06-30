import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './site-tests',
  outputDir: '.playwright-artifacts/output',
  fullyParallel: false,
  reporter: [['list'], ['json', { outputFile: process.env.PLAYWRIGHT_JSON_OUTPUT_FILE || '.playwright-artifacts/results.json' }]],
  use: {
    baseURL: process.env.SITE_BASE_URL || 'http://127.0.0.1:4173',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  },
  webServer: process.env.SITE_BASE_URL
    ? undefined
    : {
        command: 'npm run site:serve',
        url: 'http://127.0.0.1:4173',
        reuseExistingServer: !process.env.CI,
        timeout: 15_000
      },
  projects: [
    {
      name: 'desktop',
      use: { browserName: 'chromium', viewport: { width: 1440, height: 1400 } }
    },
    {
      name: 'tablet',
      use: { browserName: 'chromium', viewport: { width: 834, height: 1194 }, hasTouch: true }
    },
    {
      name: 'mobile',
      use: {
        browserName: 'chromium',
        viewport: { width: 393, height: 852 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true
      }
    }
  ]
});
