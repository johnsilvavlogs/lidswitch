import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const scanner = new URL('scan-public-secrets.mjs', import.meta.url).pathname;
const tokenBody = 'A'.repeat(30);

function runScanner(args) {
  return spawnSync(process.execPath, [scanner, ...args], {
    encoding: 'utf8'
  });
}

function makeTempRoot() {
  return mkdtempSync(join(tmpdir(), 'lidswitch-secret-scan-'));
}

function writeFixture(root, relativePath, value) {
  const parts = relativePath.split('/');
  parts.pop();
  if (parts.length > 0) {
    mkdirSync(join(root, ...parts), { recursive: true });
  }
  writeFileSync(join(root, relativePath), value);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertFailsWithoutLeakingValue(prefix) {
  const root = makeTempRoot();
  const syntheticValue = `${prefix}${tokenBody}`;
  try {
    writeFixture(root, 'leak.txt', `plain value ${syntheticValue}\n`);
    const result = runScanner(['--path', root]);

    assert(result.status === 1, `${prefix} fixture should fail the scan`);
    assert(result.stderr.includes('github-token'), `${prefix} fixture should report github-token`);
    assert(!result.stderr.includes(syntheticValue), `${prefix} fixture leaked the matched value`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function assertGithubTokenReported(root, relativePath, message) {
  const syntheticValue = `gho_${tokenBody}`;
  writeFixture(root, relativePath, `token = "${syntheticValue}"\n`);
  const result = runScanner(['--path', root]);

  assert(result.status === 1, `${message} should fail the scan`);
  assert(result.stderr.includes('github-token'), `${message} should report github-token`);
  assert(result.stderr.includes(relativePath), `${message} should report the fixture path`);
  assert(!result.stderr.includes(syntheticValue), `${message} leaked the matched value`);
}

for (const prefix of ['ghp_', 'github_pat_', 'gho_', 'ghu_', 'ghs_', 'ghr_']) {
  assertFailsWithoutLeakingValue(prefix);
}

{
  const root = makeTempRoot();
  try {
    writeFixture(root, 'note.txt', 'This mentions gho_ as a prefix, not as a token.\n');
    const result = runScanner(['--path', root]);

    assert(result.status === 0, 'benign prefix mention should pass');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

{
  const root = makeTempRoot();
  try {
    assertGithubTokenReported(
      root,
      '.codex/environments/environment.toml',
      'committed .codex environment fixture'
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

{
  const root = makeTempRoot();
  try {
    assertGithubTokenReported(
      root,
      '.codex/worktrees/019f2580/nested/secret.txt',
      'deep hidden config fixture'
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

{
  const root = makeTempRoot();
  try {
    assertGithubTokenReported(
      root,
      '.config/lidswitch/settings.toml',
      'generic hidden config fixture'
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

{
  const root = makeTempRoot();
  const ignoredValue = `gho_${tokenBody}`;
  const scannedValue = `ghp_${tokenBody}`;
  try {
    writeFixture(root, '.direnv/env', `token = "${ignoredValue}"\n`);
    writeFixture(root, '.config/lidswitch/settings.toml', `token = "${scannedValue}"\n`);
    const result = runScanner(['--path', root]);

    assert(result.status === 1, '.direnv should be excluded without skipping publishable hidden config');
    assert(result.stderr.includes('.config/lidswitch/settings.toml'), 'publishable hidden config should still be scanned');
    assert(!result.stderr.includes('.direnv/env'), '.direnv local state should not be reported');
    assert(!result.stderr.includes(ignoredValue), '.direnv fixture leaked the matched value');
    assert(!result.stderr.includes(scannedValue), 'hidden config fixture leaked the matched value');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

{
  const root = makeTempRoot();
  const syntheticValue = `gho_${tokenBody}`;
  try {
    writeFixture(root, '.jtbd-done-gate/tmp/report.txt', `token = "${syntheticValue}"\n`);
    const result = runScanner(['--path', root]);

    assert(result.status === 0, 'hidden gate state directory should stay excluded');
    assert(!result.stderr.includes(syntheticValue), 'hidden gate state fixture leaked the matched value');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

{
  const root = makeTempRoot();
  const syntheticValue = `gho_${tokenBody}`;
  try {
    writeFixture(root, 'dist/leak.txt', `plain value ${syntheticValue}\n`);

    const sourceResult = runScanner(['--path', root]);
    assert(sourceResult.status === 0, 'source scan should keep ignoring dist by default');

    const releaseResult = runScanner(['--release-artifacts', '--path', join(root, 'dist')]);
    assert(releaseResult.status === 1, 'release-artifact scan should inspect dist');
    assert(releaseResult.stderr.includes('github-token'), 'release-artifact scan should report github-token');
    assert(!releaseResult.stderr.includes(syntheticValue), 'release-artifact scan leaked the matched value');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log('public secret scanner regression ok');
