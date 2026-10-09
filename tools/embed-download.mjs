import { readFileSync, writeFileSync } from 'node:fs';
const check = process.argv.includes('--check');
for (const [source, targets, marker] of [
  ['scripts/lib/download.sh', ['install.sh', 'install.zsh', 'scripts/install-unix.sh'], '#'],
  ['scripts/lib/download.ps1', ['install.ps1', 'scripts/install-windows.ps1'], '#'],
]) {
  const block = `${marker} BEGIN GENERATED DOWNLOAD\n${readFileSync(source, 'utf8').trimEnd()}\n${marker} END GENERATED DOWNLOAD`;
  for (const file of targets) {
    const old = readFileSync(file, 'utf8');
    const next = old.replace(/# BEGIN GENERATED DOWNLOAD[\s\S]*?# END GENERATED DOWNLOAD/, () => block);
    if (next === old && !old.includes(block)) throw new Error(`missing marker: ${file}`);
    if (check && next !== old) throw new Error(`run node tools/embed-download.mjs: ${file}`);
    if (!check) writeFileSync(file, next);
  }
}
