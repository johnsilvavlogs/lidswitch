import assert from 'node:assert/strict';
import { chmodSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repository = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(repository, 'script/validate_release_tag_collision.sh');
const tag = 'v0.2.10';
const sha = '0123456789abcdef0123456789abcdef01234567';

function fixture(mode, existingReceipt) {
  const root = mkdtempSync(join(tmpdir(), 'lidswitch-tag-gate-'));
  cpSync(join(repository, 'release'), join(root, 'release'), { recursive: true });
  cpSync(join(repository, 'script'), join(root, 'script'), { recursive: true });
  writeFileSync(join(root, 'script/release.env'), `LIDSWITCH_RELEASE_TAG="${tag}"\n`);
  const fakeGit = join(root, 'fake-git');
  writeFileSync(fakeGit, `#!/bin/bash\ncase "${mode}" in\n  collision) printf '${sha}\\trefs/tags/${tag}\\n' ;;\n  absent) exit 0 ;;\n  annotated) printf '${sha}\\trefs/tags/${tag}^{}\\n' ;;\n  network) exit 7 ;;\n  malformed) printf 'not-a-tag-line\\n' ;;\n  extra) printf '${sha}\\trefs/tags/v0.2.9\\nextra\\n' ;;\nesac\n`);
  chmodSync(fakeGit, 0o755);
  const gate = join(root, 'script/validate_release_tag_collision.sh');
  writeFileSync(gate, readFileSync(source, 'utf8').replace('GIT_BIN=/usr/bin/git', `GIT_BIN=${fakeGit}`));
  chmodSync(gate, 0o755);
  const receipt = join(root, 'release/tag-collision-receipt.json');
  if (existingReceipt !== undefined) writeFileSync(receipt, existingReceipt);
  return { root, gate, receipt };
}

function run(mode, existingReceipt) {
  const value = fixture(mode, existingReceipt);
  try {
    const result = spawnSync('/bin/bash', [value.gate], { cwd: value.root, encoding: 'utf8' });
    return { ...value, result };
  } catch (error) {
    rmSync(value.root, { recursive: true, force: true });
    throw error;
  }
}

function withResult(mode, existingReceipt, verify) {
  const value = run(mode, existingReceipt);
  try {
    verify(value);
  } finally {
    rmSync(value.root, { recursive: true, force: true });
  }
}

withResult('absent', undefined, ({ result, receipt }) => {
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(readFileSync(receipt, 'utf8'));
  assert.deepEqual(Object.keys(body), ['releaseTag', 'repository', 'collisionFree', 'checkedAt']);
  assert.equal(body.releaseTag, tag);
  assert.equal(body.repository, 'johnsilvavlogs/lidswitch');
  assert.equal(body.collisionFree, true);
  assert.match(body.checkedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(statSync(receipt).mode & 0o777, 0o600);
  assert.equal(statSync(receipt).nlink, 1);
});

for (const [mode, status] of [['collision', 1], ['annotated', 1], ['network', 69], ['malformed', 70], ['extra', 70]]) {
  withResult(mode, undefined, ({ result, receipt }) => {
    assert.equal(result.status, status, mode);
    assert.equal(existsSync(receipt), false, `${mode} must not publish a receipt`);
  });
}

for (const stale of ['stale receipt\n', '{"releaseTag":"wrong"}\n']) {
  withResult('absent', stale, ({ result, receipt }) => {
    assert.equal(result.status, 74);
    assert.equal(readFileSync(receipt, 'utf8'), stale);
  });
}

console.log('release tag collision adversarial fixtures passed');
