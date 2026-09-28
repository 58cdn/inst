#!/usr/bin/env node
// Keep pinned GitHub release fallbacks in the installer aligned with upstream.
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(process.env.UPDATE_VERSIONS_ROOT || fileURLToPath(new URL('..', import.meta.url)));
const apiBase = (process.env.GITHUB_API_URL || 'https://api.github.com').replace(/\/$/, '');
const token = process.env.GITHUB_TOKEN || '';
const dryRun = process.argv.includes('--dry-run') || process.argv.includes('--check');
const userAgent = '58cdn-inst-version-sync';

function output(name, value) {
  if (!process.env.GITHUB_OUTPUT) return;
  appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`, 'utf8');
}

async function githubJson(path) {
  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': userAgent,
    'X-GitHub-Api-Version': '2022-11-28',
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`${apiBase}${path}`, { headers });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API ${response.status} for ${path}: ${body.slice(0, 300)}`);
  }
  return response.json();
}

function versionParts(value) {
  const match = String(value).trim().replace(/^v/i, '').match(/^(\d+)\.(\d+)\.(\d+)$/);
  return match ? match.slice(1).map(Number) : null;
}

function compareVersions(a, b) {
  const left = versionParts(a);
  const right = versionParts(b);
  if (!left || !right) return 0;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

function stableVersion(tag) {
  return versionParts(tag) ? String(tag).trim().replace(/^v/i, '') : '';
}

async function latestNvmWindowsRelease() {
  const repo = process.env.NVM_WINDOWS_REPOSITORY || 'nvm-windows/nvm';
  const releases = [];
  for (let page = 1; page <= 10; page += 1) {
    const pageReleases = await githubJson(`/repos/${repo}/releases?per_page=100&page=${page}`);
    if (!Array.isArray(pageReleases)) throw new Error(`Unexpected releases response for ${repo}`);
    releases.push(...pageReleases);
    if (pageReleases.length < 100) break;
  }

  const candidates = releases
    .filter((release) => !release.draft && !release.prerelease && stableVersion(release.tag_name))
    .filter((release) => Array.isArray(release.assets) && release.assets.some((asset) => asset.name === 'nvm-noinstall.zip'))
    .sort((left, right) => compareVersions(right.tag_name, left.tag_name));
  if (!candidates.length) {
    throw new Error(`No stable ${repo} release with nvm-noinstall.zip was found`);
  }
  const release = candidates[0];
  return {
    source: `${repo} release ${release.tag_name}`,
    version: stableVersion(release.tag_name),
  };
}

async function latestNvmShellRelease() {
  const repo = process.env.NVM_SHELL_REPOSITORY || 'nvm-sh/nvm';
  const release = await githubJson(`/repos/${repo}/releases/latest`);
  const version = stableVersion(release.tag_name);
  if (!version) throw new Error(`Latest ${repo} release is not a stable semver tag: ${release.tag_name}`);
  return {
    source: `${repo} release ${release.tag_name}`,
    version,
    tag: `v${version}`,
  };
}

function replaceOnce(text, pattern, replacement, label) {
  const flags = pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`;
  const count = text.match(new RegExp(pattern.source, flags))?.length || 0;
  if (count !== 1) {
    throw new Error(`${label}: expected one match, found ${count}`);
  }
  return text.replace(pattern, replacement);
}

function updateFiles(nvmWindows, nvmShell) {
  const changes = [];
  const windowsPath = resolve(root, 'scripts/install-windows.ps1');
  const windowsBefore = readFileSync(windowsPath, 'utf8');
  const windowsPattern = /(Get-Default '' 'INST_NVM_WINDOWS_VERSION' ')([0-9]+\.[0-9]+\.[0-9]+)(')/;
  const currentWindows = windowsBefore.match(windowsPattern)?.[2];
  if (!currentWindows) throw new Error('Could not read INST_NVM_WINDOWS_VERSION from scripts/install-windows.ps1');
  let windowsAfter = windowsBefore;
  if (currentWindows !== nvmWindows.version) {
    windowsAfter = replaceOnce(
      windowsAfter,
      windowsPattern,
      `$1${nvmWindows.version}$3`,
      'scripts/install-windows.ps1 nvm-windows version',
    );
    changes.push(`nvm-windows ${currentWindows} -> ${nvmWindows.version}`);
  }

  const readmePath = resolve(root, 'README.md');
  const readmeBefore = readFileSync(readmePath, 'utf8');
  const readmePattern = /(nvm-windows（默认 )[0-9]+\.[0-9]+\.[0-9]+( 免安装包)/;
  const currentReadme = readmeBefore.match(readmePattern)?.[0]?.match(/[0-9]+\.[0-9]+\.[0-9]+/)?.[0];
  if (!currentReadme) throw new Error('Could not read the nvm-windows version from README.md');
  let readmeAfter = readmeBefore;
  if (currentReadme !== nvmWindows.version) {
    readmeAfter = replaceOnce(
      readmeAfter,
      readmePattern,
      `$1${nvmWindows.version}$2`,
      'README.md nvm-windows version',
    );
  }

  const unixPath = resolve(root, 'scripts/install-unix.sh');
  const unixBefore = readFileSync(unixPath, 'utf8');
  const unixPattern = /(github_latest_tag nvm-sh\/nvm )v\d+\.\d+\.\d+/g;
  const unixMatches = unixBefore.match(unixPattern);
  if (!unixMatches || unixMatches.length < 1) {
    throw new Error('Could not read the nvm-sh fallback tag from scripts/install-unix.sh');
  }
  const currentUnix = unixMatches[0].match(/v\d+\.\d+\.\d+$/)[0];
  const unixAfter = unixBefore.replace(unixPattern, `$1${nvmShell.tag}`);
  if (currentUnix !== nvmShell.tag) {
    changes.push(`nvm-sh ${currentUnix} -> ${nvmShell.tag}`);
  }

  if (dryRun) {
    if (!changes.length && currentReadme !== nvmWindows.version) changes.push(`README nvm-windows ${currentReadme} -> ${nvmWindows.version}`);
    return changes;
  }

  if (windowsAfter !== windowsBefore) writeFileSync(windowsPath, windowsAfter, 'utf8');
  if (readmeAfter !== readmeBefore) writeFileSync(readmePath, readmeAfter, 'utf8');
  if (unixAfter !== unixBefore) writeFileSync(unixPath, unixAfter, 'utf8');
  if (currentReadme !== nvmWindows.version && !changes.some((change) => change.startsWith('nvm-windows '))) {
    changes.push(`README nvm-windows ${currentReadme} -> ${nvmWindows.version}`);
  }
  return changes;
}

try {
  const [nvmWindows, nvmShell] = await Promise.all([latestNvmWindowsRelease(), latestNvmShellRelease()]);
  const changes = updateFiles(nvmWindows, nvmShell);
  output('changed', changes.length ? 'true' : 'false');
  if (changes.length) {
    console.log(`Upstream versions: ${nvmWindows.source}; ${nvmShell.source}`);
    for (const change of changes) console.log(`Updated ${change}`);
  } else {
    console.log(`No changes (${nvmWindows.source}; ${nvmShell.source})`);
  }
} catch (error) {
  output('changed', 'false');
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
