// Builds dist/, the static site behind https://inst.linux.yun. The repository
// root is the source of truth; dist/ is generated (git-ignored) and published
// by `wrangler deploy` (Cloudflare Workers assets) or the GitHub Pages workflow.
import { copyFileSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');
// [source, path in dist]
const files = [
  ['install.sh'], ['install.zsh'], ['install.ps1'], ['install.cmd'], ['VERSION'], ['README.md'], ['mirrors.json'],
  ['scripts/install-unix.sh'], ['scripts/install-windows.ps1'],
  ['site/index.html', 'index.html'], ['site/_headers', '_headers'],
];

// A CRLF shell script breaks `curl | sh`, and cmd.exe mis-parses LF-only batch files.
for (const [file] of files) {
  const text = readFileSync(join(root, file), 'latin1');
  if (/\.(sh|zsh)$/.test(file) && text.includes('\r')) throw new Error(`${file}: must use LF line endings`);
  if (file.endsWith('.cmd') && /(^|[^\r])\n/.test(text)) throw new Error(`${file}: must use CRLF line endings`);
}
const mirrorManifest = JSON.parse(readFileSync(join(root, 'mirrors.json'), 'utf8'));
if (!Array.isArray(mirrorManifest.mirrors) || !mirrorManifest.mirrors.length) {
  throw new Error('mirrors.json: mirrors must be a non-empty array');
}
for (const mirror of mirrorManifest.mirrors) {
  if (!mirror || typeof mirror.url !== 'string' || !/^https:\/\//.test(mirror.url)) {
    throw new Error('mirrors.json: every mirror url must use HTTPS');
  }
}

rmSync(dist, { recursive: true, force: true });
for (const [from, to = from] of files) {
  mkdirSync(dirname(join(dist, to)), { recursive: true });
  copyFileSync(join(root, from), join(dist, to));
}
console.log(`built ${dist}`);
