import { expect, test } from '@playwright/test';

test('hero communicates the job and primary actions', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('note')).toContainText("For Mac jobs you can't babysit.");
  await expect(page.getByRole('heading', { name: 'Close the lid. Let the job finish.' })).toBeVisible();
  await expect(page.getByRole('link', { name: /Get the DMG/i }).first()).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch/releases/latest'
  );
  await expect(page.getByRole('link', { name: /Review source on GitHub/i }).first()).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch'
  );
  await expect(page.getByRole('link', { name: /Review source on GitHub/i }).first().locator('.github-mark')).toBeVisible();
});

test('manual install friction is explicit before download', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText(/Not App Store distributed or notarized/i)).toBeVisible();
  await expect(page.getByText(/Open Anyway/i).first()).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Straightforward, with the friction disclosed.' })).toBeVisible();
});

test('safety and open-source trust claims are visible and bounded', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('A power switch you can inspect')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Inspect it. Install it. Remove it.' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'No credentials stored' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Battery opt-in' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Easy to remove' })).toBeVisible();
});

test('hero product preview stays secondary at annotated desktop viewport', async ({ page }) => {
  await page.setViewportSize({ width: 1022, height: 728 });
  await page.goto('/');
  const productPreview = page.getByRole('img', { name: /LidSwitch menu panel/i });
  const primaryCta = page.getByRole('link', { name: /Get the DMG/i }).first();
  await expect(productPreview).toBeVisible();
  await expect(primaryCta).toBeVisible();
  await expect(page.locator('.hero-visual > img')).toHaveCount(0);

  const imageBox = await productPreview.boundingBox();
  const primaryCtaBox = await primaryCta.boundingBox();
  const heroTitleBox = await page.getByRole('heading', { name: 'Close the lid. Let the job finish.' }).boundingBox();

  expect(imageBox).not.toBeNull();
  expect(primaryCtaBox).not.toBeNull();
  expect(heroTitleBox).not.toBeNull();
  expect(imageBox.width).toBeLessThanOrEqual(460);
  expect(imageBox.x).toBeGreaterThan(heroTitleBox.x + heroTitleBox.width);
  expect(imageBox.x + imageBox.width).toBeLessThanOrEqual(1022);
  expect(primaryCtaBox.y + primaryCtaBox.height).toBeLessThanOrEqual(728);
});

test('product preview has useful accessible context without bitmap scaling', async ({ page }) => {
  await page.goto('/');
  const productPreview = page.getByRole('img', { name: /LidSwitch menu panel/i });
  await expect(productPreview).toBeVisible();
  await expect(productPreview).toHaveClass(/app-panel-preview/);
  await expect(productPreview).toHaveAttribute('aria-label', /Keep awake when plugged in/);
  await expect(productPreview).toHaveAttribute('aria-label', /Allow on battery/);
  await expect(productPreview).toHaveAttribute('aria-label', /Restore/);
});

test('architecture support is disclosed clearly', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText(/Requires an Apple Silicon Mac with macOS 14 or newer/i)).toBeVisible();
});

test('generated LidSwitch icons render in the brand and use-case cards', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('link[rel="icon"]')).toHaveAttribute('href', '/assets/lidswitch-mark.png');
  const iconPaths = [
    '/assets/lidswitch-mark.png',
    '/assets/lidswitch-build.png',
    '/assets/lidswitch-download.png',
    '/assets/lidswitch-remote.png',
    '/assets/lidswitch-backup.png'
  ];

  for (const iconPath of iconPaths) {
    const icon = page.locator(`img[src="${iconPath}"]`).first();
    await expect(icon).toBeVisible();
    await expect(icon).toHaveJSProperty('complete', true);
    await expect(icon).not.toHaveJSProperty('naturalWidth', 0);
  }
});

test('keyboard users can reach the core actions', async ({ page }) => {
  await page.goto('/');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'LidSwitch home' })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Why' })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Install', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Safety', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByLabel('Primary navigation').getByRole('link', { name: 'GitHub', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: /Get the DMG/i }).first()).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: /Review source on GitHub/i }).first()).toBeFocused();
});

test('responsive layouts avoid horizontal overflow', async ({ page }) => {
  await page.goto('/');
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  await expect(page.getByRole('link', { name: /Get the DMG/i }).first()).toBeVisible();
});

test('footer exposes install and privacy documentation links', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('contentinfo').getByRole('link', { name: 'Install notes' })).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch/blob/main/docs/INSTALL.md'
  );
  await expect(page.getByRole('contentinfo').getByRole('link', { name: 'Privacy' })).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch/blob/main/docs/PRIVACY.md'
  );
});
