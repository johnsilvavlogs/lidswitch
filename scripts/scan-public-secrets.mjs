import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const excludedDirs = new Set([
  '.build',
  '.git',
  '.jtbd-done-gate',
  'dist',
  'node_modules'
]);
const excludedFiles = new Set([
  'scripts/scan-public-secrets.mjs'
]);

const detectors = [
  ['private-key', /BEGIN (RSA|OPENSSH|PRIVATE) KEY/],
  ['openai-key', /\bsk-[A-Za-z0-9_-]{20,}\b/],
  ['github-token', /\b(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/],
  ['slack-token', /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/],
  ['aws-access-key', /\bAKIA[0-9A-Z]{16}\b/],
  ['aws-secret-assignment', /\bAWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)\b\s*[:=]\s*["']?[A-Za-z0-9/+=]{16,}/i],
  ['google-credentials-assignment', /\bGOOGLE_APPLICATION_CREDENTIALS\b\s*[:=]\s*["']?[^"'\s]{8,}/i],
  ['bearer-token', /\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._-]{20,}|\bbearer\s+[A-Za-z0-9._-]{32,}/i],
  ['generic-secret-assignment', /\b(api[_-]?key|client_secret|secret|token|password|passwd)\b\s*[:=]\s*["']?[A-Za-z0-9_./+=-]{16,}/i]
];

const findings = [];

function isLikelyText(buffer) {
  if (buffer.includes(0)) return false;
  const sample = buffer.subarray(0, 4096);
  let suspicious = 0;
  for (const byte of sample) {
    if (byte < 7 || (byte > 14 && byte < 32)) suspicious += 1;
  }
  return suspicious / Math.max(sample.length, 1) < 0.05;
}

function scanFile(path) {
  const rel = relative(root, path);
  if (excludedFiles.has(rel)) return;

  const stat = statSync(path);
  if (stat.size > 1_500_000) return;

  const buffer = readFileSync(path);
  if (!isLikelyText(buffer)) return;

  const lines = buffer.toString('utf8').split(/\r?\n/);
  lines.forEach((line, index) => {
    for (const [label, pattern] of detectors) {
      if (pattern.test(line)) {
        findings.push({ file: rel, line: index + 1, label });
      }
    }
  });
}

function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') && !['.github', '.vercelignore', '.gitignore'].includes(entry.name)) {
      if (entry.isDirectory()) continue;
    }

    const path = join(dir, entry.name);
    const rel = relative(root, path);

    if (entry.isDirectory()) {
      if (excludedDirs.has(entry.name) || excludedDirs.has(rel)) continue;
      walk(path);
      continue;
    }

    if (entry.isFile()) scanFile(path);
  }
}

walk(root);

if (findings.length > 0) {
  console.error('Potential secrets found. Values are intentionally not printed.');
  for (const finding of findings) {
    console.error(`${finding.file}:${finding.line}:${finding.label}`);
  }
  process.exit(1);
}

console.log('public secret scan ok');
