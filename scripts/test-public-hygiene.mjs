import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';

const checker = new URL('check-public-hygiene.mjs', import.meta.url).pathname;
const repoRoot = new URL('..', import.meta.url).pathname;

function makeTempRepo() {
  const root = mkdtempSync(join(tmpdir(), 'lidswitch-public-hygiene-'));
  const result = spawnSync('git', ['init', '-q'], { cwd: root, encoding: 'utf8' });
  assert(result.status === 0, `git init failed: ${result.stderr}`);
  return root;
}

function writeFixture(root, relativePath, value) {
  const target = join(root, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, value);
}

function trackFixture(root, relativePath, value) {
  writeFixture(root, relativePath, value);
  const result = spawnSync('git', ['add', '-f', relativePath], { cwd: root, encoding: 'utf8' });
  assert(result.status === 0, `git add -f ${relativePath} failed: ${result.stderr}`);
}

function runChecker(root) {
  return spawnSync(process.execPath, [checker], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LIDSWITCH_HYGIENE_ROOT: root
    }
  });
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertTrackedFileFails(relativePath) {
  const root = makeTempRepo();
  try {
    trackFixture(root, relativePath, 'export LOCAL_SETTING=dev\n');
    const result = runChecker(root);

    assert(result.status === 1, `${relativePath} should fail the hygiene check`);
    assert(result.stderr.includes(`${relativePath}: tracked local env file`), `${relativePath} failure should name the tracked env file`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function assertTrackedFilesPass(files) {
  const root = makeTempRepo();
  try {
    for (const relativePath of files) {
      trackFixture(root, relativePath, 'LOCAL_ONLY_VALUE=replace-me\n');
    }

    const result = runChecker(root);
    assert(result.status === 0, `${files.join(', ')} should pass the hygiene check: ${result.stderr}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function assertIgnoreFileIncludes(relativePath, requiredLines) {
  const lines = new Set(
    readFileSync(join(repoRoot, relativePath), 'utf8')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
  );

  for (const requiredLine of requiredLines) {
    assert(lines.has(requiredLine), `${relativePath} should include ${requiredLine}`);
  }
}

function withGlobalExcludes(patterns, callback) {
  const home = mkdtempSync(join(tmpdir(), 'lidswitch-public-hygiene-home-'));
  const originalHome = process.env.HOME;

  try {
    const excludesPath = join(home, 'global-excludes');
    writeFileSync(excludesPath, `${patterns.join('\n')}\n`);
    writeFileSync(join(home, '.gitconfig'), `[core]\n\texcludesfile = ${excludesPath}\n`);

    process.env.HOME = home;
    callback();
  } finally {
    if (originalHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = originalHome;
    }
    rmSync(home, { recursive: true, force: true });
  }
}

assertIgnoreFileIncludes('.gitignore', ['.direnv/', '.envrc', '.envrc.*']);
assertIgnoreFileIncludes('.vercelignore', ['.direnv', '.envrc', '.envrc.*']);

for (const relativePath of ['.envrc', '.envrc.local', '.env.production']) {
  assertTrackedFileFails(relativePath);
}

{
  const root = makeTempRepo();
  try {
    trackFixture(root, '.direnv/allow', 'local direnv state\n');
    const result = runChecker(root);

    assert(result.status === 1, '.direnv/allow should fail the hygiene check');
    assert(result.stderr.includes('.direnv/allow: tracked local direnv state'), '.direnv failure should name the tracked direnv state');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

assertTrackedFilesPass(['.env.example', '.env.sample', '.envrc.example', '.envrc.sample']);

withGlobalExcludes(['.env*', '.direnv'], () => {
  assertTrackedFileFails('.envrc');
  assertTrackedFileFails('.envrc.local');

  const root = makeTempRepo();
  try {
    trackFixture(root, '.direnv/allow', 'local direnv state\n');
    const result = runChecker(root);

    assert(result.status === 1, '.direnv/allow should fail the hygiene check even when globally ignored');
    assert(result.stderr.includes('.direnv/allow: tracked local direnv state'), '.direnv failure should name the globally ignored direnv state');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

console.log('public hygiene regression ok');
