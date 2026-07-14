import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const result = spawnSync('/usr/bin/python3', [fileURLToPath(new URL('test-public-secrets.py', import.meta.url))], { stdio: 'inherit' });
if (result.error || result.status === null) {
  console.error('public secret scanner regression failed: python-launch-failed');
  process.exitCode = 2;
} else {
  process.exitCode = result.status;
}
