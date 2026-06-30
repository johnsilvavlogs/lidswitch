import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const publicRoots = ['README.md', 'docs', 'site'];
const textExtensions = new Set(['.html', '.md']);

function walk(path, files = []) {
  const fullPath = join(root, path);
  if (!existsSync(fullPath)) return files;
  const info = statSync(fullPath);
  if (info.isDirectory()) {
    for (const entry of readdirSync(fullPath)) {
      if (entry === 'node_modules' || entry === '.git') continue;
      walk(join(path, entry), files);
    }
  } else {
    files.push(path);
  }
  return files;
}

for (const file of walk('.')) {
  const base = file.split('/').pop();
  if (base?.startsWith('._') || base === '.DS_Store') {
    throw new Error(`macOS metadata file must not be committed or bundled: ${file}`);
  }
}

const publicFiles = publicRoots.flatMap((entry) => walk(entry))
  .filter((file) => textExtensions.has(extname(file)));

function isExternal(target) {
  return /^(https?:|mailto:|tel:)/i.test(target);
}

function withoutAnchor(target) {
  return target.split('#')[0];
}

function assertExistingTarget(source, rawTarget) {
  const target = withoutAnchor(rawTarget.trim());
  if (!target || isExternal(target)) return;
  if (target.startsWith('/_vercel/')) return;

  const decoded = decodeURIComponent(target);
  const baseDir = dirname(source);
  const candidate = decoded.startsWith('/')
    ? join(root, 'site', decoded)
    : join(root, baseDir, decoded);
  const normalized = normalize(candidate);

  if (!normalized.startsWith(root)) {
    throw new Error(`Link escapes repo root in ${source}: ${rawTarget}`);
  }

  if (!existsSync(normalized)) {
    throw new Error(`Broken public link in ${source}: ${rawTarget}`);
  }
}

for (const file of publicFiles) {
  const content = readFileSync(join(root, file), 'utf8');

  for (const match of content.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
    assertExistingTarget(file, match[1]);
  }

  if (extname(file) === '.html') {
    for (const match of content.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
      assertExistingTarget(file, match[1]);
    }
  }
}

console.log('public link check ok');
