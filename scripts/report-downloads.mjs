const owner = 'johnsilvavlogs';
const repo = 'lidswitch';
const apiBase = `https://api.github.com/repos/${owner}/${repo}`;

async function fetchJson(url) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'lidswitch-download-report'
    }
  });

  if (!response.ok) {
    throw new Error(`${url} returned ${response.status}`);
  }

  return response.json();
}

const release = await fetchJson(`${apiBase}/releases/latest`);
const assets = release.assets ?? [];

console.log(`Release: ${release.name ?? release.tag_name} (${release.html_url})`);

for (const name of ['LidSwitch.dmg', 'LidSwitch.dmg.sha256']) {
  const asset = assets.find((item) => item.name === name);
  if (!asset) {
    console.log(`${name}: missing`);
    continue;
  }

  console.log(`${name}: ${asset.download_count} downloads, ${asset.size} bytes`);
}
