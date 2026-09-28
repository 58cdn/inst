// Root User-Agent routing of worker/index.mjs against a stub ASSETS binding.
//   node tests/worker.test.mjs
import assert from 'node:assert/strict';
import worker, { entryFor } from '../worker/index.mjs';

const env = {
  ASSETS: {
    async fetch(input) {
      const request = new Request(input);
      const path = new URL(request.url).pathname;
      const type = path === '/' ? 'text/html' : 'application/octet-stream';
      return new Response(request.method === 'HEAD' ? null : `asset ${path}`, { headers: { 'Content-Type': type } });
    },
  },
};
const get = (path, ua, method = 'GET') =>
  worker.fetch(new Request(`https://inst.linux.yun${path}`, { method, headers: ua ? { 'User-Agent': ua } : {} }), env);

const cases = [
  ['curl/8.7.1', '/install.sh'],
  ['Wget/1.21.4', '/install.sh'],
  ['', '/install.sh'],
  ['Mozilla/5.0 (Windows NT 10.0; Microsoft Windows 10.0.26200; zh-CN) WindowsPowerShell/5.1.26100.6584', '/install.ps1'],
  ['Mozilla/5.0 (Windows NT 10.0; Microsoft Windows 10.0.26200; zh-CN) PowerShell/7.5.3', '/install.ps1'],
  ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36', null],
];
for (const [ua, entry] of cases) {
  assert.equal(entryFor(ua), entry, ua);
  const res = await get('/', ua);
  assert.equal(await res.text(), `asset ${entry || '/'}`, ua);
  assert.match(res.headers.get('Vary'), /User-Agent/, ua);
  assert.equal(res.headers.get('Content-Type'), entry ? 'text/plain; charset=utf-8' : 'text/html', ua);
}

const head = await get('/', 'curl/8.7.1', 'HEAD');
assert.equal(head.status, 200);
assert.equal(await head.text(), '');
const other = await get('/scripts/install-unix.sh', 'curl/8.7.1');
assert.equal(await other.text(), 'asset /scripts/install-unix.sh');
assert.equal(other.headers.get('Vary'), null);
console.log('PASS: worker routes "/" by User-Agent and passes other paths through');
