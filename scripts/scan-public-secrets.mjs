import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const sourceExcludedDirs = new Set([
  '.agents',
  '.build',
  '.claude',
  '.codex',
  '.cursor',
  '.git',
  '.jtbd-done-gate',
  '.oracle',
  '.playwright-artifacts',
  '.tmp',
  '.vercel',
  'coverage',
  'DerivedData',
  'dist',
  'node_modules',
  'pkg',
  'playwright-report',
  'test-results',
  'tmp',
  'work'
]);
const releaseExcludedDirs = new Set([
  '.git',
  '.jtbd-done-gate',
  'node_modules',
  'playwright-report',
  'test-results'
]);
const excludedFiles = new Set([
  'scripts/scan-public-secrets.mjs'
]);

const detectors = [
  ['private-key', /BEGIN (RSA|OPENSSH|PRIVATE) KEY/],
  ['openai-key', /\bsk-[A-Za-z0-9_-]{20,}\b/],
  ['github-token', /\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/],
  ['slack-token', /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/],
  ['aws-access-key', /\bAKIA[0-9A-Z]{16}\b/],
  ['aws-secret-assignment', /\bAWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)\b\s*[:=]\s*["']?[A-Za-z0-9/+=]{16,}/i],
  ['google-credentials-assignment', /\bGOOGLE_APPLICATION_CREDENTIALS\b\s*[:=]\s*["']?[^"'\s]{8,}/i],
  ['bearer-token', /\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._-]{20,}|\bbearer\s+[A-Za-z0-9._-]{32,}/i],
  ['generic-secret-assignment', /\b(api[_-]?key|client_secret|secret|token|password|passwd)\b\s*[:=]\s*["']?[A-Za-z0-9_./+=-]{16,}/i]
];

const findings = [];
const options = parseOptions(process.argv.slice(2));
const excludedDirs = options.releaseArtifacts ? releaseExcludedDirs : sourceExcludedDirs;
const scanRoots = resolveScanRoots(options);

function parseOptions(args) {
  try {
    return parseArgs(args);
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}

function parseArgs(args) {
  const parsed = {
    paths: [],
    releaseArtifacts: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--release-artifacts') {
      parsed.releaseArtifacts = true;
      continue;
    }

    if (arg === '--path') {
      const value = args[index + 1];
      if (!value) {
        throw new Error('--path requires a value');
      }
      parsed.paths.push(value);
      index += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  return parsed;
}

function resolveScanRoots(parsed) {
  const requested = parsed.paths.length > 0
    ? parsed.paths
    : [parsed.releaseArtifacts ? join(root, 'dist') : root];

  return requested.map((requestedPath) => {
    const scanRoot = isAbsolute(requestedPath) ? requestedPath : join(root, requestedPath);
    return resolve(scanRoot);
  });
}

function isLikelyText(buffer) {
  if (buffer.includes(0)) return false;
  const sample = buffer.subarray(0, 4096);
  let suspicious = 0;
  for (const byte of sample) {
    if (byte < 7 || (byte > 14 && byte < 32)) suspicious += 1;
  }
  return suspicious / Math.max(sample.length, 1) < 0.05;
}

function displayPath(scanRoot, path) {
  const repoRel = relative(root, path);
  if (repoRel && !repoRel.startsWith('..')) {
    return repoRel;
  }

  return relative(scanRoot, path) || path;
}

function scanFile(scanRoot, path) {
  const rel = displayPath(scanRoot, path);
  const repoRel = relative(root, path);
  if (!repoRel.startsWith('..') && excludedFiles.has(repoRel)) return;

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

function walk(scanRoot, dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') && !['.github', '.vercelignore', '.gitignore'].includes(entry.name)) {
      if (entry.isDirectory()) continue;
    }

    const path = join(dir, entry.name);
    const rel = relative(scanRoot, path);

    if (entry.isDirectory()) {
      if (excludedDirs.has(entry.name) || excludedDirs.has(rel)) continue;
      walk(scanRoot, path);
      continue;
    }

    if (entry.isFile()) scanFile(scanRoot, path);
  }
}

try {
  for (const scanRoot of scanRoots) {
    if (!existsSync(scanRoot)) {
      throw new Error(`Scan path does not exist: ${scanRoot}`);
    }

    const stat = statSync(scanRoot);
    if (stat.isDirectory()) {
      walk(scanRoot, scanRoot);
    } else if (stat.isFile()) {
      scanFile(scanRoot, scanRoot);
    }
  }
} catch (error) {
  console.error(error.message);
  process.exit(2);
}

if (findings.length > 0) {
  console.error('Potential secrets found. Values are intentionally not printed.');
  for (const finding of findings) {
    console.error(`${finding.file}:${finding.line}:${finding.label}`);
  }
  process.exit(1);
}

console.log('public secret scan ok');
