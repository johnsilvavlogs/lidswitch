const owner = 'johnsilvavlogs';
const repo = 'lidswitch';
const apiBase = `https://api.github.com/repos/${owner}/${repo}`;

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

const repoInfo = await fetchJson(apiBase);

if (repoInfo.private !== false) {
  throw new Error('GitHub repository is not public to anonymous API requests.');
}

if (repoInfo.license?.spdx_id !== 'MIT') {
  throw new Error(`Expected MIT license metadata, got ${repoInfo.license?.spdx_id ?? 'none'}.`);
}

const release = await fetchJson(`${apiBase}/releases/latest`);

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
if (!dmg?.digest?.startsWith('sha256:')) {
  throw new Error('Latest DMG asset is missing a sha256 digest.');
}

console.log(`public GitHub check ok: ${repoInfo.html_url} ${release.html_url}`);
