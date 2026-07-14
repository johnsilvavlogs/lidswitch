import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { inflateSync } from 'node:zlib';

const root = new URL('..', import.meta.url).pathname;

const sitePngAssets = [
  ['site/assets/lidswitch-mark-144-fa9aa1a5f70f.png', 144],
  ['site/assets/lidswitch-mark-216-0dfd7ed43dba.png', 216],
  ['site/assets/lidswitch-build-128-32d9a22b8bef.png', 128],
  ['site/assets/lidswitch-build-192-16148c6dbb79.png', 192],
  ['site/assets/lidswitch-download-128-88721556621f.png', 128],
  ['site/assets/lidswitch-download-192-50fe09a31826.png', 192],
  ['site/assets/lidswitch-remote-128-e68486b746b9.png', 128],
  ['site/assets/lidswitch-remote-192-bd6b203d8092.png', 192],
  ['site/assets/lidswitch-backup-128-c7f4569f8f2e.png', 128],
  ['site/assets/lidswitch-backup-192-df8b916b0850.png', 192]
];

const siteWebpAssets = [
  ['site/assets/lidswitch-mark-144-24888dd9f963.webp', 144],
  ['site/assets/lidswitch-mark-216-cc502ae318f3.webp', 216],
  ['site/assets/lidswitch-build-128-c15b207f7e81.webp', 128],
  ['site/assets/lidswitch-build-192-27e61624aaae.webp', 192],
  ['site/assets/lidswitch-download-128-1a57405f8ece.webp', 128],
  ['site/assets/lidswitch-download-192-8b15b3c6dfc5.webp', 192],
  ['site/assets/lidswitch-remote-128-fc12eb115458.webp', 128],
  ['site/assets/lidswitch-remote-192-cb5f1dc71eec.webp', 192],
  ['site/assets/lidswitch-backup-128-80f92a0eb8f5.webp', 128],
  ['site/assets/lidswitch-backup-192-366f2fef9ed3.webp', 192]
];

const appPngAssets = [
  ['Resources/LidSwitchIcon.png', 1024]
];

const siteHtml = readFileSync(join(root, 'site/index.html'), 'utf8');
const candidateAssembler = readFileSync(join(root, 'script/assemble_manual_adhoc_candidate.py'), 'utf8');

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

function readLosslessWebp(filePath) {
  const bytes = readFileSync(filePath);
  if (bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WEBP') {
    throw new Error(`${filePath} is not a WebP.`);
  }

  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const type = bytes.toString('ascii', offset, offset + 4);
    const length = bytes.readUInt32LE(offset + 4);
    const dataStart = offset + 8;
    if (type === 'VP8L') {
      if (bytes[dataStart] !== 0x2f) {
        throw new Error(`${filePath} has an invalid lossless WebP header.`);
      }
      const bits = bytes.readUInt32LE(dataStart + 1);
      return {
        width: (bits & 0x3fff) + 1,
        height: ((bits >>> 14) & 0x3fff) + 1
      };
    }
    offset = dataStart + length + (length % 2);
  }

  throw new Error(`${filePath} must be lossless VP8L WebP.`);
}

for (const [relativePath, expectedSize] of [...sitePngAssets, ...appPngAssets]) {
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

for (const [relativePath, expectedSize] of siteWebpAssets) {
  const absolutePath = join(root, relativePath);
  if (!existsSync(absolutePath)) {
    throw new Error(`Missing WebP asset: ${relativePath}`);
  }
  const webp = readLosslessWebp(absolutePath);
  if (webp.width !== expectedSize || webp.height !== expectedSize) {
    throw new Error(`${relativePath} expected ${expectedSize}x${expectedSize}, got ${webp.width}x${webp.height}.`);
  }
}

for (const asset of [...sitePngAssets, ...siteWebpAssets].map(([relativePath]) => `/${relativePath.replace(/^site\//, '')}`)) {
  if (!siteHtml.includes(asset)) {
    throw new Error(`Site does not reference generated icon asset: ${asset}`);
  }
}

if (!siteHtml.includes('<picture') || !siteHtml.includes('type="image/webp"')) {
  throw new Error('Site must provide WebP sources with PNG fallbacks.');
}

if (/\/assets\/lidswitch-(mark|build|download|remote|backup)\.png/.test(siteHtml)) {
  throw new Error('Site must not reference legacy oversized PNG source assets.');
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
if (!candidateAssembler.includes('"CFBundleIconFile": "LidSwitch"')
    || !candidateAssembler.includes('Resources" / "LidSwitch.icns"')
    || !candidateAssembler.includes('resources / "LidSwitch.icns"')
    || candidateAssembler.includes('if icon.is_file')) {
  throw new Error('Immutable candidate assembler must require, copy, and declare the generated ICNS asset.');
}

console.log('icon check ok');
