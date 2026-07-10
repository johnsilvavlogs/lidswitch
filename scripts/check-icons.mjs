import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { inflateSync } from 'node:zlib';

const root = new URL('..', import.meta.url).pathname;

const pngAssets = [
  ['site/assets/lidswitch-mark.png', 512],
  ['site/assets/lidswitch-build.png', 512],
  ['site/assets/lidswitch-download.png', 512],
  ['site/assets/lidswitch-remote.png', 512],
  ['site/assets/lidswitch-backup.png', 512],
  ['Resources/LidSwitchIcon.png', 1024]
];

const siteHtml = readFileSync(join(root, 'site/index.html'), 'utf8');
const buildScript = readFileSync(join(root, 'script/build_app_bundle.sh'), 'utf8');

function readPng(filePath) {
  const bytes = readFileSync(filePath);
  if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error(`${filePath} is not a PNG.`);
  }

  let offset = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  const idat = [];

  while (offset < bytes.length) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    offset += length + 12;

    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
  }

  if (bitDepth !== 8 || colorType !== 6) {
    throw new Error(`${filePath} must be 8-bit RGBA PNG; found bitDepth=${bitDepth}, colorType=${colorType}.`);
  }

  const bpp = 4;
  const stride = width * bpp;
  const inflated = inflateSync(Buffer.concat(idat));
  const rgba = Buffer.alloc(height * stride);
  let inputOffset = 0;

  for (let y = 0; y < height; y += 1) {
    const filter = inflated[inputOffset];
    inputOffset += 1;
    const rowStart = y * stride;
    const prevRowStart = (y - 1) * stride;

    for (let x = 0; x < stride; x += 1) {
      const raw = inflated[inputOffset + x];
      const left = x >= bpp ? rgba[rowStart + x - bpp] : 0;
      const up = y > 0 ? rgba[prevRowStart + x] : 0;
      const upperLeft = y > 0 && x >= bpp ? rgba[prevRowStart + x - bpp] : 0;

      let value;
      if (filter === 0) {
        value = raw;
      } else if (filter === 1) {
        value = raw + left;
      } else if (filter === 2) {
        value = raw + up;
      } else if (filter === 3) {
        value = raw + Math.floor((left + up) / 2);
      } else if (filter === 4) {
        const p = left + up - upperLeft;
        const pa = Math.abs(p - left);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - upperLeft);
        value = raw + (pa <= pb && pa <= pc ? left : pb <= pc ? up : upperLeft);
      } else {
        throw new Error(`${filePath} uses unsupported PNG filter ${filter}.`);
      }

      rgba[rowStart + x] = value & 255;
    }

    inputOffset += stride;
  }

  let transparent = 0;
  let partial = 0;
  let opaque = 0;
  for (let i = 3; i < rgba.length; i += 4) {
    if (rgba[i] === 0) {
      transparent += 1;
    } else if (rgba[i] === 255) {
      opaque += 1;
    } else {
      partial += 1;
    }
  }

  const alphaAt = (x, y) => rgba[y * stride + x * bpp + 3];
  return {
    width,
    height,
    transparent,
    partial,
    opaque,
    corners: [
      alphaAt(0, 0),
      alphaAt(width - 1, 0),
      alphaAt(0, height - 1),
      alphaAt(width - 1, height - 1)
    ]
  };
}

for (const [relativePath, expectedSize] of pngAssets) {
  const absolutePath = join(root, relativePath);
  if (!existsSync(absolutePath)) {
    throw new Error(`Missing icon asset: ${relativePath}`);
  }

  const png = readPng(absolutePath);
  if (png.width !== expectedSize || png.height !== expectedSize) {
    throw new Error(`${relativePath} expected ${expectedSize}x${expectedSize}, got ${png.width}x${png.height}.`);
  }
  if (png.corners.some((alpha) => alpha !== 0)) {
    throw new Error(`${relativePath} does not have transparent corners.`);
  }
  if (png.transparent < png.width * png.height * 0.25 || png.opaque < png.width * png.height * 0.2) {
    throw new Error(`${relativePath} has implausible alpha coverage.`);
  }
}

for (const asset of pngAssets.slice(0, 5).map(([relativePath]) => `/${relativePath.replace(/^site\//, '')}`)) {
  if (!siteHtml.includes(asset)) {
    throw new Error(`Site does not reference generated icon asset: ${asset}`);
  }
}

const icnsPath = join(root, 'Resources/LidSwitch.icns');
if (!existsSync(icnsPath)) {
  throw new Error('Missing Resources/LidSwitch.icns.');
}
if (readFileSync(icnsPath).toString('ascii', 0, 4) !== 'icns') {
  throw new Error('Resources/LidSwitch.icns is not an ICNS file.');
}
if (statSync(icnsPath).size < 100_000) {
  throw new Error('Resources/LidSwitch.icns is unexpectedly small.');
}
if (!buildScript.includes('CFBundleIconFile') || !buildScript.includes('Resources/$APP_NAME.icns')) {
  throw new Error('App bundle script does not integrate the generated ICNS asset.');
}

console.log('icon check ok');
