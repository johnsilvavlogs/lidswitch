import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { extname, join, resolve } from 'node:path';

const root = process.env.LIDSWITCH_HYGIENE_ROOT
  ? resolve(process.env.LIDSWITCH_HYGIENE_ROOT)
  : new URL('..', import.meta.url).pathname;

const trackedFiles = execFileSync('git', ['ls-files', '-z'], {
  cwd: root,
  encoding: 'buffer'
})
  .toString('utf8')
  .split('\0')
  .filter(Boolean);

const blockedPathRules = [
  ['build output', /^(?:\.build|DerivedData|dist)(?:\/|$)/],
  ['coverage output', /^(?:coverage|playwright-report|test-results|\.playwright-artifacts)(?:\/|$)/],
  ['local agent state', /^(?:\.codex|\.agents|\.oracle|\.claude|\.cursor)(?:\/|$)/],
  ['local done-gate state', /^\.jtbd-done-gate(?:\.json|\/|$)/],
  ['local Vercel state', /^\.vercel(?:\/|$)/],
  ['local direnv state', /^\.direnv(?:\/|$)/],
  ['local scratch workspace', /^(?:work|tmp|\.tmp|pkg)(?:\/|$)/],
  ['release binary', /\.(?:dmg|pkg)$/],
  ['Xcode result bundle', /(?:^|\/)[^/]+\.xcresult(?:\/|$)/],
  ['macOS metadata', /(?:^|\/)(?:\.DS_Store|._[^/]+)$/]
];

const blockedContentRules = [
  ['absolute user path', /\/Users\/johnsilva\//],
  ['macOS temp transcript path', /\/private\/var\/folders\//],
  ['done-gate report path', /\.jtbd-done-gate\/reports\//],
  ['Codex clipboard artifact', /codex-clipboard-[0-9a-f-]+/i],
  ['browser comment artifact', /# Browser comments:/],
  ['Oracle loop instruction artifact', /\$oracle-production-loop|oracle-production-loop/],
  ['Loop Engineering instruction artifact', /\$loop-engineering-manager|loop-engineering-manager/]
];

const textExtensions = new Set([
  '',
  '.css',
  '.html',
  '.js',
  '.json',
  '.md',
  '.mjs',
  '.sh',
  '.swift',
  '.txt',
  '.yml',
  '.yaml'
]);
const contentRuleExemptions = new Set([
  'scripts/check-public-hygiene.mjs'
]);

function isBlockedEnvFile(file) {
  const name = file.split('/').pop() ?? '';
  return (name === '.env'
    || name.startsWith('.env.')
    || name === '.envrc'
    || name.startsWith('.envrc.'))
    && !name.endsWith('.example')
    && !name.endsWith('.sample');
}

function isTextFile(file) {
  return textExtensions.has(extname(file));
}

const findings = [];

for (const file of trackedFiles) {
  for (const [label, pattern] of blockedPathRules) {
    if (pattern.test(file)) {
      findings.push(`${file}: tracked ${label}`);
    }
  }

  if (isBlockedEnvFile(file)) {
    findings.push(`${file}: tracked local env file`);
  }

  if (!isTextFile(file) || contentRuleExemptions.has(file)) continue;

  const absolutePath = join(root, file);
  if (!existsSync(absolutePath)) continue; // A pending tracked deletion is not part of the candidate tree.
  const stat = statSync(absolutePath);
  if (stat.size > 1_500_000) continue;

  const content = readFileSync(absolutePath, 'utf8');
  for (const [label, pattern] of blockedContentRules) {
    if (pattern.test(content)) {
      findings.push(`${file}: contains ${label}`);
    }
  }
}

if (findings.length > 0) {
  console.error('Public hygiene check failed: local process artifacts must not be tracked.');
  for (const finding of findings) {
    console.error(`- ${finding}`);
  }
  process.exit(1);
}

console.log('public hygiene check ok');
