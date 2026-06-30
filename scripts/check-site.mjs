import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const html = readFileSync(join(root, 'site/index.html'), 'utf8');
const css = readFileSync(join(root, 'site/styles.css'), 'utf8');
const screenshot = statSync(join(root, 'site/assets/lidswitch-panel.png'));
const publicTextFiles = [
  'README.md',
  'docs/INSTALL.md',
  'docs/PRIVACY.md',
  'docs/DISTRIBUTION.md',
  'docs/VALIDATION.md',
  'site/index.html'
];

const required = [
  'Close the lid. Let the job finish.',
  'Review source on GitHub',
  'Not App Store distributed or notarized',
  'Open Anyway',
  'No credentials stored',
  'Battery opt-in',
  'Keep awake when plugged in',
  'Allow on battery',
  'Requires an Apple Silicon Mac with macOS 14 or newer',
  'not affiliated with Apple'
];

for (const phrase of required) {
  if (!html.includes(phrase)) {
    throw new Error(`Missing required site phrase: ${phrase}`);
  }
}

const forbidden = [
  /App Store badge/i,
  /notarized by Apple/i,
  /official Apple/i,
  /\\b\\d+[kK]?\\+?\\s+stars\\b/,
  /testimonial/i,
  /enterprise[- ]grade security/i,
  /collects? analytics/i,
  /tracks? users/i
];

for (const pattern of forbidden) {
  if (pattern.test(html)) {
    throw new Error(`Forbidden or unsupported public claim found: ${pattern}`);
  }
}

for (const file of publicTextFiles) {
  const content = readFileSync(join(root, file), 'utf8');
  if (/\/Users\/[A-Za-z0-9._-]+/.test(content)) {
    throw new Error(`Public-facing file contains a machine-specific path: ${file}`);
  }
}

const links = [
  'https://github.com/johnsilvavlogs/lidswitch',
  'https://github.com/johnsilvavlogs/lidswitch/releases/latest',
  'https://github.com/johnsilvavlogs/lidswitch/blob/main/docs/INSTALL.md',
  'https://github.com/johnsilvavlogs/lidswitch/blob/main/docs/PRIVACY.md'
];

for (const link of links) {
  if (!html.includes(`href="${link}"`)) {
    throw new Error(`Missing expected public link: ${link}`);
  }
}

if (!css.includes('@media (max-width: 680px)')) {
  throw new Error('Missing mobile responsive stylesheet block.');
}

if (screenshot.size < 50_000) {
  throw new Error('Site product screenshot is unexpectedly small or missing.');
}

console.log('site check ok');
