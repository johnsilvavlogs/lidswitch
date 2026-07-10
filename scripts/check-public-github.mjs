import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const owner = 'johnsilvavlogs';
const repo = 'lidswitch';
const apiBase = `https://api.github.com/repos/${owner}/${repo}`;
const packageVersion = JSON.parse(readFileSync(resolve('package.json'), 'utf8')).version;
const expectedTag = process.env.LIDSWITCH_EXPECTED_TAG ?? `v${packageVersion}`;
const expectedCommit = process.env.LIDSWITCH_EXPECTED_COMMIT
  ?? execFileSync('/usr/bin/git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
const checksumLine = readFileSync(resolve('dist/LidSwitch.dmg.sha256'), 'utf8').trim();
const expectedDigest = checksumLine.split(/\s+/)[0];

async function fetchJson(url) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'lidswitch-public-launch-check'
    }
  });

  if (!response.ok) {
    throw new Error(`${url} returned ${response.status}`);
  }

  return response.json();
}

async function fetchText(url) {
  const response = await fetch(url, {
    headers: { 'User-Agent': 'lidswitch-public-launch-check' }
  });
  if (!response.ok) {
    throw new Error(`${url} returned ${response.status}`);
  }
  return response.text();
}

const repoInfo = await fetchJson(apiBase);

if (repoInfo.private !== false) {
  throw new Error('GitHub repository is not public to anonymous API requests.');
}

if (repoInfo.license?.spdx_id !== 'MIT') {
  throw new Error(`Expected MIT license metadata, got ${repoInfo.license?.spdx_id ?? 'none'}.`);
}

const release = await fetchJson(`${apiBase}/releases/latest`);

if (release.tag_name !== expectedTag) {
  throw new Error(`Expected latest tag ${expectedTag}, got ${release.tag_name ?? 'none'}.`);
}

if (!release.name?.includes(expectedTag.replace(/^v/, ''))) {
  throw new Error(`Latest release name does not identify ${expectedTag}.`);
}

if (release.draft) {
  throw new Error('Latest release is still a draft.');
}

if (release.prerelease) {
  throw new Error('Latest release is marked prerelease.');
}

const assetNames = new Set((release.assets ?? []).map((asset) => asset.name));

for (const requiredAsset of ['LidSwitch.dmg', 'LidSwitch.dmg.sha256']) {
  if (!assetNames.has(requiredAsset)) {
    throw new Error(`Latest release is missing asset: ${requiredAsset}`);
  }
}

const dmg = release.assets.find((asset) => asset.name === 'LidSwitch.dmg');
if (dmg?.digest !== `sha256:${expectedDigest}`) {
  throw new Error(`Remote DMG digest does not match local artifact ${expectedDigest}.`);
}

const checksumAsset = release.assets.find((asset) => asset.name === 'LidSwitch.dmg.sha256');
const remoteChecksum = (await fetchText(checksumAsset.browser_download_url)).trim();
if (remoteChecksum !== checksumLine) {
  throw new Error('Remote checksum asset content does not match the final local checksum file.');
}

const tagRef = await fetchJson(`${apiBase}/git/ref/tags/${expectedTag}`);
let tagCommit = tagRef.object?.sha;
if (tagRef.object?.type === 'tag') {
  const annotatedTag = await fetchJson(`${apiBase}/git/tags/${tagRef.object.sha}`);
  tagCommit = annotatedTag.object?.sha;
}
if (tagCommit !== expectedCommit) {
  throw new Error(`Release tag points to ${tagCommit ?? 'none'}, expected ${expectedCommit}.`);
}

const latestRedirect = await fetch(`https://github.com/${owner}/${repo}/releases/latest`, {
  redirect: 'manual',
  headers: { 'User-Agent': 'lidswitch-public-launch-check' }
});
const location = latestRedirect.headers.get('location') ?? '';
if (![301, 302].includes(latestRedirect.status) || !location.endsWith(`/tag/${expectedTag}`)) {
  throw new Error(`Latest release redirect does not resolve to ${expectedTag}.`);
}

console.log(`public GitHub check ok: ${repoInfo.html_url} ${release.html_url} ${expectedDigest}`);
