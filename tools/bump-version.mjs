#!/usr/bin/env node
// VERSION is authoritative. Runtime scripts remain standalone (including the PS 5.1 BOM).
import {readFileSync, writeFileSync, appendFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

const pattern = /^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$/;
const scripts = [
  ['scripts/install-windows.ps1', /^\$InstVersion = '([^']+)'$/gm, v => `$InstVersion = '${v}'`],
  ['scripts/install-unix.sh', /^INST_VERSION="([^"]+)"$/gm, v => `INST_VERSION="${v}"`],
];
const paths = ['VERSION', ...scripts.map(([path]) => path)];
const root = fileURLToPath(new URL('..', import.meta.url));

export function nextVersion(version, part = 'patch') {
  if (!pattern.test(version)) throw new Error(`Invalid release version: ${version}`);
  const index = ['major', 'minor', 'patch'].indexOf(part);
  if (index < 0) throw new Error('Use patch, minor or major');
  const values = version.split('.').map(Number);
  values[index]++;
  for (let i = index + 1; i < values.length; i++) values[i] = 0;
  const next = values.join('.');
  if (!pattern.test(next)) throw new Error('Release version component exceeds 999999999');
  return next;
}

function replacements(read, version) {
  return scripts.map(([path, expression, format]) => {
    const text = read(path);
    const matches = [...text.matchAll(expression)];
    if (matches.length !== 1 || matches[0][1] !== version) {
      throw new Error(`${path}: expected exactly one version assignment matching VERSION (${version})`);
    }
    return [path, text, expression, format];
  });
}

export function checkVersion(directory = root) {
  const read = path => readFileSync(resolve(directory, path), 'utf8');
  const version = read('VERSION').trim();
  if (!pattern.test(version)) throw new Error('VERSION must contain a stable major.minor.patch');
  replacements(read, version);
  return version;
}

export function bumpVersion(directory = root, part = 'patch') {
  const current = checkVersion(directory);
  const next = nextVersion(current, part);
  const changes = replacements(path => readFileSync(resolve(directory, path), 'utf8'), current)
    .map(([path, text, expression, format]) => [path, text.replace(expression, () => format(next))]);
  // Validate all inputs before writing any file. No unrelated formatting or BOM changes.
  for (const [path, text] of [...changes, ['VERSION', `${next}\n`]]) {
    writeFileSync(resolve(directory, path), text, 'utf8');
  }
  return next;
}

function git(directory, ...args) {
  return execFileSync('git', args, {cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
}

// Recognize only a direct, version-only child, not merely a commit with a matching subject.
function isReleaseCommit(directory, commit, source = '') {
  try {
    const parent = git(directory, 'show', '-s', '--format=%P', commit).trim();
    if (!/^[a-f0-9]{40}$/.test(parent) || (source && source !== parent)) return false;
    const message = git(directory, 'show', '-s', '--format=%B', commit);
    if (!message.split('\n').includes(`Inst-Source: ${parent}`)) return false;
    const previous = git(directory, 'show', `${parent}:VERSION`).trim();
    const next = nextVersion(previous);
    if (message.split('\n')[0] !== `chore(release): v${next}`) return false;
    const changed = git(directory, 'diff', '--name-only', parent, commit).trim().split('\n').sort();
    if (changed.join('\n') !== [...paths].sort().join('\n')) return false;
    if (git(directory, 'show', `${commit}:VERSION`) !== `${next}\n`) return false;
    for (const [path, text, expression, format] of replacements(path => git(directory, 'show', `${parent}:${path}`), previous)) {
      if (git(directory, 'show', `${commit}:${path}`) !== text.replace(expression, () => format(next))) return false;
    }
    return true;
  } catch { return false; }
}

export function prepareRelease(directory, source, branch) {
  if (!/^[a-f0-9]{40}$/.test(source)) throw new Error('A full tested commit SHA is required');
  git(directory, 'check-ref-format', `refs/heads/${branch}`);
  if (git(directory, 'rev-parse', 'HEAD').trim() !== source) throw new Error('Checkout must match the tested commit');
  if (git(directory, 'status', '--porcelain').trim()) throw new Error('Refusing to release a dirty worktree');
  checkVersion(directory);
  git(directory, 'fetch', '--no-tags', 'origin', branch);
  const latest = git(directory, 'rev-parse', 'FETCH_HEAD').trim();
  if (latest !== source) {
    if (isReleaseCommit(directory, latest, source)) {
      return {ready: true, sha: latest, version: git(directory, 'show', `${latest}:VERSION`).trim()};
    }
    return {ready: false, sha: '', version: '', reason: 'Default branch advanced; its own CI must publish it'};
  }
  if (isReleaseCommit(directory, source)) {
    return {ready: true, sha: source, version: checkVersion(directory)};
  }
  const version = bumpVersion(directory);
  git(directory, 'add', '--', ...paths);
  git(directory, 'commit', '-m', `chore(release): v${version}`, '-m', `Inst-Source: ${source}`);
  const sha = git(directory, 'rev-parse', 'HEAD').trim();
  // A concurrent push or branch protection rejects this normally; never force-push.
  git(directory, 'push', 'origin', `HEAD:refs/heads/${branch}`);
  return {ready: true, sha, version};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args[0] === '--release' && args.length === 3) {
      const result = prepareRelease(root, args[1], args[2]);
      if (process.env.GITHUB_OUTPUT) {
        for (const name of ['ready', 'sha', 'version']) {
          appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${result[name]}\n`);
        }
      }
      console.log(result.ready ? `Release v${result.version}: ${result.sha}` : result.reason);
    } else if (args.length === 1 && args[0] === '--check') {
      console.log(`Release versions agree: ${checkVersion()}`);
    } else if (args.length <= 1 && (!args[0] || ['major', 'minor', 'patch'].includes(args[0]))) {
      console.log(`Release version: ${bumpVersion(root, args[0] || 'patch')}`);
    } else {
      throw new Error('Usage: node tools/bump-version.mjs [--check|patch|minor|major|--release SHA BRANCH]');
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
