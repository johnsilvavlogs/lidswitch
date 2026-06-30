import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const html = readFileSync(join(root, 'site/index.html'), 'utf8');
const normalizedHtml = html.replace(/\s+/g, ' ');
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
  'Plug in. Close the lid. Let the run finish.',
  'Free DMG and source are on GitHub',
  'app-panel-preview',
  'Download free DMG',
  'Review source on GitHub',
  'github-mark',
  'Manual install, disclosed up front',
  'not App Store distributed or notarized',
  'Open Anyway',
  'No credentials or telemetry',
  'does not collect, transmit, or store',
  'Battery stays opt-in',
  'Trust through control',
  'Keep awake when plugged in',
  'Allow on battery',
  'Apple Silicon Macs on macOS 14 or newer',
  'Source is public on GitHub',
  'https://github.com/johnsilvavlogs/lidswitch',
  'https://github.com/johnsilvavlogs/lidswitch/releases/latest',
  'not affiliated with Apple'
];

for (const phrase of required) {
  if (!html.includes(phrase) && !normalizedHtml.includes(phrase)) {
    throw new Error(`Missing required site phrase: ${phrase}`);
  }
}

const forbidden = [
  /App Store badge/i,
  /notarized by Apple/i,
  /official Apple/i,
  /Free manual DMG for technical friends/i,
  /No App Store promises/i,
  /pending final approval/i,
  /remain private until final approval/i,
  /Check DMG status/i,
  /Preview install steps/i,
  /Release status/i,
  />\s*For technical friends\s*</i,
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

if (/<img[^>]+lidswitch-panel\.png/i.test(html)) {
  throw new Error('Hero must not render the low-resolution product screenshot as a scaled img.');
}

for (const file of publicTextFiles) {
  const content = readFileSync(join(root, file), 'utf8');
  if (/\/Users\/[A-Za-z0-9._-]+/.test(content)) {
    throw new Error(`Public-facing file contains a machine-specific path: ${file}`);
  }
}

const links = [
  'https://github.com/johnsilvavlogs/lidswitch/releases/latest',
  'https://github.com/johnsilvavlogs/lidswitch',
  '#install',
  '#safety'
];

for (const link of links) {
  if (!html.includes(`href="${link}"`)) {
    throw new Error(`Missing expected public link: ${link}`);
  }
}

const downloadPage = readFileSync(join(root, 'site/download/index.html'), 'utf8');
if (!/github\.com\/johnsilvavlogs\/lidswitch\/releases\/latest/i.test(downloadPage)) {
  throw new Error('Download page must point to the public GitHub release.');
}

if (!/http-equiv="refresh"/i.test(downloadPage)) {
  throw new Error('Download page must redirect to GitHub Releases.');
}

if (/private until final approval|pending final approval|DMG status/i.test(downloadPage)) {
  throw new Error('Download page still contains pre-launch placeholder copy.');
}

if (!css.includes('@media (max-width: 680px)')) {
  throw new Error('Missing mobile responsive stylesheet block.');
}

if (screenshot.size < 50_000) {
  throw new Error('Site product screenshot is unexpectedly small or missing.');
}

console.log('site check ok');
