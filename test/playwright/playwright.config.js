const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  testMatch: '*.spec.js',
  timeout: 90000,
  expect: { timeout: 10000 },
  workers: 1,
  retries: 0,
  reporter: [['list'], ['json', { outputFile: process.env.QA_RESULTS_FILE || 'qa-results.json' }]],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: process.env.RAILS_URL || 'http://localhost:3000',
    actionTimeout: 10000,
    navigationTimeout: 15000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
});
