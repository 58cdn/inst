import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read=p=>readFileSync(resolve(root,p),'utf8');
const win=read('scripts/install-windows.ps1');
const unix=read('scripts/install-unix.sh');
const version=read('VERSION').trim();
assert.ok(win.includes(`$InstVersion = '${version}'`) && unix.includes(`INST_VERSION="${version}"`), 'Release version mismatch');
for(const key of [...Array.from({length:14},(_,i)=>String(i+1)),'0']) {
  assert.match(win,new RegExp(`Write-MenuLine ['\"]?${key}['\"]? `));
}
for(const key of [...Array.from({length:11},(_,i)=>String(i+1)),'0']) {
  assert.match(unix,new RegExp(`menu_line ${key} `));
}
for(const group of ['开发环境','网络与镜像','AI 工具','常用工具','inst 维护']) {
  assert.ok(win.includes(group) && unix.includes(group),group);
}
assert.match(win,/Write-MenuLine 10 'Windows 激活管理'/);
assert.match(win,/'10' \{ Invoke-MenuAction \{ Install-Activation \}/);
assert.match(win,/Write-MenuLine 9 'Windows 系统管理'/);
assert.match(win,/'9' \{ Invoke-MenuAction \{ Install-WindowsManagement \}/);
assert.ok(win.includes("Write-MenuSection '工具与系统'") && win.includes('-WindowsManagement'));
assert.ok(!/menu_line 12 /.test(unix));
for(const name of ['Install-WindowsManagement','Install-Activation','Install-Cgpu']) {
  assert.equal(win.split(`function ${name} {`).length-1,1,`Duplicate/missing installer: ${name}`);
}
assert.ok(!/menu_line 13 /.test(unix));
const all=win.match(/if \(\$All\) \{([^}]+)\}/)[1];
assert.ok(!/Activation|Cgpu|WindowsManagement/.test(all));
assert.match(unix,/all_in_one\(\)\{ install_node; install_python; configure_mirrors; install_agents; \}/);
const activation=read('scripts/activation.ps1');
assert.ok(!/Invoke-Expression|Invoke-WebRequest|Invoke-RestMethod|DownloadString|Invoke-CimMethod|slmgr|ospp|Set-MpPreference|Set-ItemProperty/i.test(activation));
for(const file of ['VERSION','install.sh','install.zsh','install.ps1','install.cmd','scripts/install-unix.sh','scripts/install-windows.ps1','scripts/cgpu.ps1','scripts/cgpu.cmd','scripts/cgpu.md','scripts/activation.ps1','scripts/activation.cmd','scripts/activation.md','scripts/winmanage.ps1','scripts/winmanage.cmd','scripts/winmanage.md','docs/architecture.md',...['README','runtime','mirrors','agents','tools','activation','system','maintenance'].map(n=>`docs/features/${n}.md`)]) {
  assert.ok(existsSync(resolve(root,'dist',file)),`Missing published path: ${file}`);
  assert.deepEqual(readFileSync(resolve(root,file)),readFileSync(resolve(root,'dist',file)),`Published bytes differ: ${file}`);
}
for(const file of ['README.md','docs/architecture.md',...['README','runtime','mirrors','agents','tools','activation','system','maintenance'].map(n=>`docs/features/${n}.md`)]) {
  for(const m of read(file).matchAll(/\]\(([^)]+)\)/g)) {
    const link=m[1].split('#')[0];
    if(!link || /^[a-z]+:/i.test(link)) continue;
    assert.ok(existsSync(resolve(root,dirname(file),link)),`${file}: broken link ${link}`);
  }
}
assert.ok(readFileSync(resolve(root,'scripts/activation.ps1')).subarray(0,3).equals(Buffer.from([239,187,191])));
assert.ok(!/(^|[^\r])\n/.test(read('scripts/activation.cmd')));
console.log('PASS: feature groups, consecutive menu keys, activation isolation, published assets, local links and encodings');
