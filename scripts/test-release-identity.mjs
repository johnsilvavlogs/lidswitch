import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const repository = join(dirname(fileURLToPath(import.meta.url)), '..');
const rendererSource = join(repository, 'scripts/render-release-identity.mjs');
const identity = {
  schemaVersion: 1,
  appVersion: '0.2.10',
  appBuild: 2,
  helperVersion: 5,
  xpcProtocolVersion: 2,
  enrollmentPolicyProtocolVersion: 1,
  releaseTag: 'v0.2.10',
  appBundleIdentifier: 'com.johnsilva.LidSwitch',
  helperLabel: 'com.johnsilva.lidswitch.helper',
  machService: 'com.johnsilva.lidswitch.helper.control',
  qualifiedSystemBuild: '25F84',
  channel: 'manual-ad-hoc'
};

function run(root, arguments_ = []) {
  return execFileSync(process.execPath, [join(root, 'scripts/render-release-identity.mjs'), ...arguments_], {
    cwd: root,
    encoding: 'utf8',
    stdio: 'pipe'
  });
}

function expectRejected(label, mutate) {
  const root = makeFixture();
  try {
    mutate(root);
    assert.throws(() => run(root), undefined, label);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function writeIdentity(root, value) {
  writeFileSync(join(root, 'release/identity.json'), `${JSON.stringify(value, null, 2)}\n`);
}

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), 'lidswitch-release-identity-'));
  for (const directory of [
    'scripts', 'script', 'release', 'Resources', 'Sources/LidSwitchCore',
    'Sources/LidSwitchXPCBridge/include', 'Sources/LidSwitch/Support',
    'site/assets', 'site/download', 'screenshots'
  ]) mkdirSync(join(root, directory), { recursive: true });
  copyFileSync(rendererSource, join(root, 'scripts/render-release-identity.mjs'));
  writeIdentity(root, identity);
  run(root, ['--write']);
  writeFileSync(join(root, 'package.json'), JSON.stringify({ version: identity.appVersion }, null, 2));
  writeFileSync(join(root, 'package-lock.json'), JSON.stringify({
    version: identity.appVersion,
    packages: { '': { version: identity.appVersion } }
  }, null, 2));
  writeFileSync(join(root, 'site/index.html'), `macOS 26.5.2 build ${identity.qualifiedSystemBuild}`);
  writeFileSync(join(root, 'site/download/index.html'), `macOS 26.5.2 build ${identity.qualifiedSystemBuild}`);
  writeFileSync(join(root, 'site/styles.css'), '');
  return root;
}

{
  const root = makeFixture();
  try {
    run(root); // Default check is the wrapper contract used by both package scripts.
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

expectRejected('unknown identity key', (root) => writeIdentity(root, { ...identity, unknown: 'value' }));
expectRejected('missing identity key', (root) => {
  const value = { ...identity };
  delete value.appBuild;
  writeIdentity(root, value);
});
expectRejected('reordered identity key', (root) => writeIdentity(root, {
  appVersion: identity.appVersion,
  schemaVersion: identity.schemaVersion,
  ...Object.fromEntries(Object.entries(identity).slice(2))
}));
expectRejected('duplicate conceptual key', (root) => {
  const path = join(root, 'release/identity.json');
  const raw = readFileSync(path, 'utf8');
  writeFileSync(path, raw.replace('  "appVersion": "0.2.10",\n', '  "appVersion": "0.2.10",\n  "appVersion": "0.2.10",\n'));
});

for (const [label, mutate] of [
  ['wrong app build type', (value) => { value.appBuild = '2'; }],
  ['out-of-range helper version', (value) => { value.helperVersion = 0; }],
  ['non-normalized app version', (value) => { value.appVersion = '00.2.10'; }],
  ['protocol conflation', (value) => { value.enrollmentPolicyProtocolVersion = value.xpcProtocolVersion; }],
  ['derived tag drift', (value) => { value.releaseTag = 'v9.9.9'; }],
  ['unsafe helper identifier', (value) => { value.helperLabel = 'com.johnsilva.lidswitch.<helper>'; }],
  ['path-like mach service', (value) => { value.machService = '../helper.control'; }],
  ['XML-hazard qualified build', (value) => { value.qualifiedSystemBuild = '25F<84'; }]
]) {
  expectRejected(label, (root) => {
    const value = { ...identity };
    mutate(value);
    writeIdentity(root, value);
  });
}

expectRejected('generated mirror drift', (root) => {
  const path = join(root, 'Sources/LidSwitchCore/ReleaseIdentity.generated.swift');
  writeFileSync(path, `${readFileSync(path, 'utf8')}// hand edit\n`);
});
expectRejected('obsolete generated mirror', (root) => {
  writeFileSync(join(root, 'Sources/LidSwitchCore/ReleaseIdentity.obsolete.swift'), '// obsolete\n');
});
expectRejected('package version drift', (root) => {
  writeFileSync(join(root, 'package.json'), JSON.stringify({ version: '0.2.9' }));
});
expectRejected('site qualified-build drift', (root) => {
  writeFileSync(join(root, 'site/index.html'), 'macOS 26.5.2 build 25F85');
});
expectRejected('site release-version drift', (root) => {
  writeFileSync(join(root, 'site/download/index.html'), `macOS 26.5.2 build ${identity.qualifiedSystemBuild} ${identity.appVersion}`);
});
expectRejected('retired panel asset return', (root) => {
  writeFileSync(join(root, 'site/assets/lidswitch-panel.png'), 'retired');
});
expectRejected('retired working screenshot return', (root) => {
  writeFileSync(join(root, 'screenshots/lidswitch-working.png'), 'retired');
});
expectRejected('retired working screenshot reference', (root) => {
  writeFileSync(join(root, 'site/index.html'), `macOS 26.5.2 build ${identity.qualifiedSystemBuild} lidswitch-working.png`);
});

console.log('release identity adversarial fixtures passed');
