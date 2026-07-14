import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const html = readFileSync(join(root, 'site/index.html'), 'utf8');
const normalizedHtml = html.replace(/\s+/g, ' ');
const css = readFileSync(join(root, 'site/styles.css'), 'utf8');
const releaseEnv = readFileSync(join(root, 'script/release.env'), 'utf8');
const vercelConfig = JSON.parse(readFileSync(join(root, 'vercel.json'), 'utf8'));
const publicTextFiles = [
  'README.md',
  'docs/INSTALL.md',
  'docs/PRIVACY.md',
  'docs/DISTRIBUTION.md',
  'docs/VALIDATION.md',
  'site/index.html',
  'site/download/index.html'
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
  'No app telemetry',
  'The Mac app sends no passwords',
  'Vercel Web Analytics',
  'GitHub counts release downloads',
  'Battery stays unchanged',
  'Trust through control',
  'Prepare Safe Helper',
  'Start Plugged-In Session',
  'Stop and Restore',
  'never rearms automatically',
  'macOS 26.5.2 build 25F84',
  'Source is public on GitHub',
  'https://github.com/johnsilvavlogs/lidswitch',
  'https://github.com/johnsilvavlogs/lidswitch/releases/latest',
  '/_vercel/insights/script.js',
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
  /tracks? users/i,
  /Allow on battery/i,
  /Battery stays opt-in/i,
  /StartInterval/i
];

for (const pattern of forbidden) {
  if (pattern.test(html)) {
    throw new Error(`Forbidden or unsupported public claim found: ${pattern}`);
  }
}

if (html.includes('lidswitch-panel.png') || html.includes('lidswitch-working.png')) {
  throw new Error('A retired product screenshot must not return to the public site.');
}
if (existsSync(join(root, 'site/assets/lidswitch-panel.png')) || existsSync(join(root, 'screenshots/lidswitch-working.png'))) {
  throw new Error('A retired product screenshot asset must not return to the repository.');
}

for (const file of publicTextFiles) {
  const content = readFileSync(join(root, file), 'utf8');
  if (/\/Users\/[A-Za-z0-9._-]+/.test(content)) {
    throw new Error(`Public-facing file contains a machine-specific path: ${file}`);
  }
}

const links = [
  '/download/',
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
if (downloadPage.includes('lidswitch-panel.png') || downloadPage.includes('lidswitch-working.png')) {
  throw new Error('A retired product screenshot must not return to the download page.');
}
const releaseVersion = releaseEnv.match(/^LIDSWITCH_APP_VERSION="([^"]+)"$/m)?.[1];
if (!releaseVersion) {
  throw new Error('script/release.env must define LIDSWITCH_APP_VERSION.');
}

if (/\bversion\s+\d+\.\d+\.\d+/i.test(downloadPage)) {
  throw new Error('Download page must not carry a drift-prone hardcoded release version.');
}

if (downloadPage.includes('0.2.5') || downloadPage.includes(releaseVersion)) {
  throw new Error('Download page version truth must come from the current GitHub release link, not static copy.');
}

if (!/github\.com\/johnsilvavlogs\/lidswitch\/releases\/latest/i.test(downloadPage)) {
  throw new Error('Download page must point to the public GitHub release.');
}

if (!downloadPage.includes('/_vercel/insights/script.js')) {
  throw new Error('Download page must include Vercel Web Analytics.');
}

if (!downloadPage.includes('download intent')) {
  throw new Error('Download page must disclose that Vercel Web Analytics measures download intent.');
}

if (!/http-equiv="refresh"/i.test(downloadPage)) {
  throw new Error('Download page must redirect to GitHub Releases.');
}

if (!downloadPage.includes('GitHub Releases opens in three seconds.')) {
  throw new Error('Download page must visibly communicate the three-second GitHub handoff.');
}

if (!downloadPage.includes('does not claim that the DMG is installed')) {
  throw new Error('Download page must not imply installation or download completion.');
}

if (/private until final approval|pending final approval|DMG status/i.test(downloadPage)) {
  throw new Error('Download page still contains pre-launch placeholder copy.');
}

if (!css.includes('@media (max-width: 680px)')) {
  throw new Error('Missing mobile responsive stylesheet block.');
}

if (!css.includes('@media (prefers-reduced-motion: reduce)')) {
  throw new Error('Missing reduced-motion stylesheet block.');
}

const immutableAssetHeader = vercelConfig.headers?.find(
  (rule) =>
    rule.source?.includes('/assets/lidswitch-') &&
    rule.source.includes('[a-f0-9]{12}') &&
    rule.headers?.some(
      (header) => header.key === 'Cache-Control' && header.value === 'public, max-age=31536000, immutable'
    )
);
if (!immutableAssetHeader) {
  throw new Error('Fingerprint-named site assets must have immutable one-year Vercel caching.');
}

console.log('site check ok');
