import { expect, test } from '@playwright/test';

test('hero communicates the job and primary actions', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('note')).toContainText('Free DMG and source are on GitHub.');
  await expect(page.getByRole('heading', { name: 'Close the lid. Let the job finish.' })).toBeVisible();
  await expect(page.getByRole('link', { name: /Download free DMG/i }).first()).toHaveAttribute(
    'href',
    '/download/'
  );
  await expect(page.getByRole('link', { name: /Review source on GitHub/i }).first()).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch'
  );
  await expect(page.getByRole('link', { name: /Review source on GitHub/i }).first().locator('.github-mark')).toBeVisible();
});

test('manual install friction is explicit before download', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText(/Manual install, disclosed up front/i)).toBeVisible();
  await expect(page.getByText(/not App Store distributed or\s+notarized/i)).toBeVisible();
  await expect(page.getByText(/Open Anyway/i).first()).toBeVisible();
  await expect(page.getByRole('heading', { name: 'A manual install with the approval steps up front.' })).toBeVisible();
});

test('safety and public-source trust claims are visible and bounded', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('Trust through control')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Know what changes. Undo it fast.' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'No app telemetry' })).toBeVisible();
  await expect(page.getByText(/Vercel Web Analytics for aggregate traffic/i)).toBeVisible();
  await expect(page.getByText(/GitHub counts release downloads/i)).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Battery stays unchanged' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Restore is not hidden' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Source is public' })).toBeVisible();
});

test('hero product preview stays secondary at annotated desktop viewport', async ({ page }) => {
  await page.setViewportSize({ width: 1022, height: 728 });
  await page.goto('/');
  const productPreview = page.getByRole('img', { name: /LidSwitch menu panel/i });
  const primaryCta = page.getByRole('link', { name: /Download free DMG/i }).first();
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
  await expect(productPreview).toHaveAttribute('aria-label', /Prepare Safe Helper/);
  await expect(productPreview).toHaveAttribute('aria-label', /Start Plugged-In Session/);
  await expect(productPreview).toHaveAttribute('aria-label', /Stop and Restore/);
});

test('architecture support is disclosed clearly', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText(/macOS 26\.5\.2 build 25F84/i).first()).toBeVisible();
  await expect(page.getByText(/Other builds remain off/i)).toBeVisible();
});

test('responsive lossless LidSwitch icons render in the brand and use-case cards', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('link[rel="icon"]')).toHaveAttribute(
    'href',
    '/assets/lidswitch-mark-144-fa9aa1a5f70f.png'
  );
  await expect(page.locator('picture.brand-mark source[type="image/webp"]')).toHaveCount(1);
  await expect(page.locator('picture.case-icon source[type="image/webp"]')).toHaveCount(4);

  const iconPaths = [
    '/assets/lidswitch-mark-144-fa9aa1a5f70f.png',
    '/assets/lidswitch-build-128-32d9a22b8bef.png',
    '/assets/lidswitch-download-128-88721556621f.png',
    '/assets/lidswitch-remote-128-e68486b746b9.png',
    '/assets/lidswitch-backup-128-c7f4569f8f2e.png'
  ];

  for (const iconPath of iconPaths) {
    const icon = page.locator(`img[src="${iconPath}"]`).first();
    await expect(icon).toBeVisible();
    await expect(icon).toHaveJSProperty('complete', true);
    await expect(icon).not.toHaveJSProperty('naturalWidth', 0);
  }

  for (const icon of await page.locator('picture.case-icon img').all()) {
    await expect(icon).toHaveAttribute('loading', 'lazy');
    await expect(icon).toHaveAttribute('decoding', 'async');
  }

  await expect(page.locator('img[src$="lidswitch-mark.png"], img[src$="lidswitch-build.png"]')).toHaveCount(0);
});

test('mobile navigation and footer links have usable targets and reduced motion is honored', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');

  for (const link of await page.getByLabel('Primary navigation').getByRole('link').all()) {
    const box = await link.boundingBox();
    expect(box?.height).toBeGreaterThanOrEqual(44);
  }

  for (const link of await page.getByRole('contentinfo').getByRole('link').all()) {
    const box = await link.boundingBox();
    expect(box?.height).toBeGreaterThanOrEqual(44);
  }

  await expect.poll(() => page.evaluate(() => getComputedStyle(document.documentElement).scrollBehavior)).toBe('auto');
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
  await expect(page.getByLabel('Primary navigation').getByRole('link', { name: 'Install', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByLabel('Primary navigation').getByRole('link', { name: 'Safety', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByLabel('Primary navigation').getByRole('link', { name: 'GitHub', exact: true })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: /Download free DMG/i }).first()).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: /Review source on GitHub/i }).first()).toBeFocused();
});

test('skip link transfers focus into main content', async ({ page }) => {
  await page.goto('/');
  await page.keyboard.press('Tab');
  await page.keyboard.press('Enter');
  await expect(page.locator('main#main')).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: /Download free DMG/i }).first()).toBeFocused();
});

test('responsive layouts avoid horizontal overflow', async ({ page }) => {
  await page.goto('/');
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  await expect(page.getByRole('link', { name: /Download free DMG/i }).first()).toBeVisible();
});

test('footer exposes GitHub release and local install/privacy anchors', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('contentinfo').getByRole('link', { name: 'GitHub' })).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch'
  );
  await expect(page.getByRole('contentinfo').getByRole('link', { name: 'Releases' })).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch/releases/latest'
  );
  await expect(page.getByRole('contentinfo').getByRole('link', { name: 'Install' })).toHaveAttribute(
    'href',
    '#install'
  );
  await expect(page.getByRole('contentinfo').getByRole('link', { name: 'Privacy' })).toHaveAttribute(
    'href',
    '#safety'
  );
});

test('download page hands off to GitHub Releases', async ({ page }) => {
  await page.goto('/download/', { waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'Opening the current LidSwitch release.' })).toBeVisible();
  await expect(page.getByText(/DMG is published on GitHub Releases/i)).toBeVisible();
  await expect(page.getByText(/not App Store distributed or notarized/i)).toBeVisible();
  await expect(page.getByText(/Open Anyway/i)).toBeVisible();
  await expect(page.getByText(/download intent/i)).toBeVisible();
  await expect(page.getByRole('status')).toHaveText('GitHub Releases opens in three seconds.');
  await expect(page.getByText(/does not claim that the DMG is installed/i)).toBeVisible();
  await expect(page.locator('meta[http-equiv="refresh"]')).toHaveAttribute(
    'content',
    '3; url=https://github.com/johnsilvavlogs/lidswitch/releases/latest'
  );
  await expect(page.getByRole('link', { name: 'Open GitHub Releases now' })).toHaveAttribute(
    'href',
    'https://github.com/johnsilvavlogs/lidswitch/releases/latest'
  );
  await expect(page.getByRole('link', { name: 'Return to LidSwitch' })).toHaveAttribute('href', '/');
});

test('Vercel Web Analytics script is present on public pages', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('script[src="/_vercel/insights/script.js"]')).toHaveCount(1);
  await page.goto('/download/', { waitUntil: 'domcontentloaded' });
  await expect(page.locator('script[src="/_vercel/insights/script.js"]')).toHaveCount(1);
});
