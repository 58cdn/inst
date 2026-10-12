import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {nextVersion, checkVersion, bumpVersion, prepareRelease} from '../tools/bump-version.mjs';

const scratch = mkdtempSync(join(tmpdir(), 'inst-release-test-'));
const git = (cwd, ...args) => execFileSync('git', args, {cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
function fixture(name) {
  const dir = join(scratch, name);
  mkdirSync(join(dir, 'scripts'), {recursive: true});
  writeFileSync(join(dir, 'VERSION'), '1.2.9\n');
  writeFileSync(join(dir, 'scripts/install-windows.ps1'), "\uFEFF# standalone\n$InstVersion = '1.2.9'\n# 中文保留\n");
  writeFileSync(join(dir, 'scripts/install-unix.sh'), '#!/bin/bash\nINST_VERSION="1.2.9"\n# unchanged\n');
  return dir;
}
try {
  assert.equal(nextVersion('1.2.9'), '1.2.10');
  assert.equal(nextVersion('1.9.99', 'minor'), '1.10.0');
  assert.equal(nextVersion('1.9.99', 'major'), '2.0.0');
  for (const value of ['1.2', 'v1.2.3', '01.2.3', '1.2.3.4', '1.2.3-beta', '9999999999.1.1']) {
    assert.throws(() => nextVersion(value));
  }
  assert.throws(() => nextVersion('1.2.999999999'));
  const dir = fixture('versions');
  assert.equal(bumpVersion(dir), '1.2.10');
  assert.equal(checkVersion(dir), '1.2.10');
  assert.equal(readFileSync(join(dir, 'scripts/install-windows.ps1'), 'utf8'), "\uFEFF# standalone\n$InstVersion = '1.2.10'\n# 中文保留\n");
  assert.equal(readFileSync(join(dir, 'scripts/install-unix.sh'), 'utf8'), '#!/bin/bash\nINST_VERSION="1.2.10"\n# unchanged\n');
  writeFileSync(join(dir, 'VERSION'), '1.2.11\n');
  const before = readFileSync(join(dir, 'scripts/install-windows.ps1'));
  assert.throws(() => bumpVersion(dir), /matching VERSION/);
  assert.deepEqual(readFileSync(join(dir, 'scripts/install-windows.ps1')), before);
  assert.equal(readFileSync(join(dir, 'VERSION'), 'utf8'), '1.2.11\n');
  console.log('PASS: numeric versions, synchronized constants, BOM preservation and fail-before-write');

  const work = fixture('work');
  const remote = join(scratch, 'remote.git');
  git(scratch, 'init', '--bare', remote);
  git(work, 'init', '-b', 'master');
  git(work, 'config', 'user.name', 'Release test');
  git(work, 'config', 'user.email', 'release-test@example.invalid');
  git(work, 'config', 'core.autocrlf', 'false');
  git(work, 'add', '.');
  git(work, 'commit', '-m', 'fixture');
  git(work, 'remote', 'add', 'origin', remote);
  git(work, 'push', '-u', 'origin', 'master');
  const source = git(work, 'rev-parse', 'HEAD');
  const first = prepareRelease(work, source, 'master');
  assert.equal(first.ready, true);
  assert.equal(first.version, '1.2.10');
  assert.equal(git(remote, 'rev-parse', 'master'), first.sha);
  assert.equal(git(work, 'show', '-s', '--format=%P', first.sha), source);
  assert.deepEqual(prepareRelease(work, first.sha, 'master'), first, 'manual rerun must not bump again');
  git(work, 'checkout', '--detach', source);
  assert.deepEqual(prepareRelease(work, source, 'master'), first, 'rerun original tested SHA must reuse its release');
  assert.equal(git(work, 'rev-parse', 'HEAD'), source);

  git(work, 'checkout', 'master');
  writeFileSync(join(work, 'README.md'), 'another change\n');
  git(work, 'add', '.');
  // A forged-looking subject/trailer with extra changes is NOT a version-only release.
  git(work, 'commit', '-m', 'chore(release): v1.2.11', '-m', `Inst-Source: ${first.sha}`);
  git(work, 'push', 'origin', 'master');
  const newer = git(work, 'rev-parse', 'HEAD');
  git(work, 'checkout', '--detach', source);
  assert.equal(prepareRelease(work, source, 'master').ready, false, 'stale CI must not publish');
  assert.equal(git(remote, 'rev-parse', 'master'), newer);
  git(work, 'checkout', '--detach', newer);
  const second = prepareRelease(work, newer, 'master');
  assert.equal(second.version, '1.2.11');

  writeFileSync(join(work, 'README.md'), 'uncommitted\n');
  assert.throws(() => prepareRelease(work, second.sha, 'master'), /dirty worktree/);
  git(work, 'add', '.');
  git(work, 'commit', '-m', 'test rejected push');
  git(work, 'push', 'origin', 'HEAD:refs/heads/master');
  const rejectedSource = git(work, 'rev-parse', 'HEAD');
  const hook = join(remote, 'hooks/pre-receive');
  writeFileSync(hook, '#!/bin/sh\nexit 1\n');
  chmodSync(hook, 0o755);
  assert.throws(() => prepareRelease(work, rejectedSource, 'master'));
  assert.equal(git(remote, 'rev-parse', 'master'), rejectedSource, 'rejected release must leave remote unchanged');
  console.log('PASS: release push, idempotent reruns, stale CI, dirty tree and rejected-push safeguards (local Git only)');
} finally {
  rmSync(scratch, {recursive: true, force: true});
}
