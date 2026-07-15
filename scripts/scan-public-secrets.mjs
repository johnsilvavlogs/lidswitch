import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const python = '/usr/bin/python3';
const scanner = fileURLToPath(new URL('scan-public-secrets.py', import.meta.url));
const result = spawnSync(python, [scanner, ...process.argv.slice(2)], { stdio: 'inherit' });

if (result.error || result.status === null) {
  console.error('public secret scan failed: python-launch-failed');
  process.exitCode = 2;
} else {
  process.exitCode = result.status;
}
