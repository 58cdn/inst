#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" INST_PREFIX="$scratch/prefix" INST_SHELL_RC="$scratch/profile"
export INST_REGION=global INST_NO_UPDATE_CHECK=1 INST_NO_TTY=1 NO_COLOR=1
unset INST_RAW_BASE_URL INST_INSTALLER_PATH INST_MIRROR_PRESET INST_GH_PROXY || true
mkdir -p "$HOME" "$scratch/bin"
export PATH="$scratch/bin:$PATH"
export TEST_OS=Darwin TEST_ARCH=arm64
cat > "$scratch/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -s ]]; then echo "$TEST_OS"; else echo "$TEST_ARCH"; fi
EOF
chmod +x "$scratch/bin/uname"
inst(){ bash "$root/scripts/install-unix.sh" "$@" < /dev/null; }
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ "$(inst --version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '--version'
grep -q "^INST_VERSION=\"$(tr -d '[:space:]' < "$root/VERSION")\"$" "$root/scripts/install-unix.sh" || fail 'VERSION file mismatch'
# macOS libc treats bytes 0x80-0xFF as letters in UTF-8 locales, so bash reads an unbraced
# $NAME directly followed by non-ASCII text (e.g. a full-width comma) as a longer, unset name,
# which is fatal under set -u; zsh does the same with CJK letters. Write ${NAME} there.
unbraced=$(cd "$root" && LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' install.sh install.zsh scripts/*.sh tests/*.sh || true)
[[ -z "$unbraced" ]] || fail "unbraced variable before non-ASCII text:"$'\n'"$unbraced"

inst --all --dry-run > "$scratch/dry-run"
grep -q 'Miniconda3-latest-MacOSX-arm64.sh' "$scratch/dry-run" || fail 'mac miniconda url'
grep -q 'download and execute .*claude.ai/install.sh' "$scratch/dry-run" || fail 'claude official installer'
grep -q 'download and execute .*chatgpt.com/codex/install.sh' "$scratch/dry-run" || fail 'codex official installer'
test ! -e "$INST_PREFIX" || fail 'dry-run created prefix'
test ! -e "$INST_SHELL_RC" || fail 'dry-run touched shell rc'
test ! -e "$HOME/.config/inst" || fail 'dry-run created env dir'
export TEST_OS=Linux TEST_ARCH=x86_64
inst --python --dry-run > "$scratch/linux"
grep -q 'Miniconda3-latest-Linux-x86_64.sh' "$scratch/linux" || fail 'linux miniconda url'
INST_REGION=cn inst --python --dry-run > "$scratch/linux-cn"
grep -q 'mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Linux-x86_64.sh' "$scratch/linux-cn" || fail 'cn miniconda mirror'
if inst --prefix > "$scratch/error" 2>&1; then fail 'missing argument accepted'; fi
if inst --agents --agent-list nope --dry-run > "$scratch/agent-error" 2>&1; then fail 'unknown agent accepted'; fi
if inst --agents --agent-method brew > /dev/null 2>&1; then fail 'bad agent method accepted'; fi
if inst > "$scratch/no-args" 2>&1; then fail 'no-args without tty should exit non-zero'; fi
grep -q -- '--all' "$scratch/no-args" || fail 'no-args should print usage'
inst --agents --agent-list all --agent-method npm --dry-run > "$scratch/agents-npm"
grep -q 'npm install --global opencode-ai' "$scratch/agents-npm" || fail 'opencode npm'
grep -q 'download and execute .*x.ai' "$scratch/agents-npm" || fail 'grok falls back to official'
grep -q 'npm install --global @earendil-works/pi-coding-agent' "$scratch/agents-npm" || fail 'pi npm'
grep -q 'download and execute .*hermes-agent.nousresearch.com/install.sh --skip-setup' "$scratch/agents-npm" || fail 'hermes official args'
echo 'PASS: dry-run, platform URLs, region mirrors, argument errors, agent table'

# A download error must not execute a partial installer or print completion.
cat > "$scratch/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$scratch/bin/curl"
if inst --node > "$scratch/failure" 2>&1; then fail 'download error reported as success'; fi
if grep -q '所选步骤执行结束' "$scratch/failure"; then fail 'success printed after failure'; fi
export INST_DESKTOP_CLAUDE_URL=http://example.invalid/setup
if inst --desktop --dry-run > "$scratch/desktop" 2>&1; then fail 'insecure URL accepted'; fi
if grep -q '+ curl' "$scratch/desktop"; then fail 'insecure URL downloaded'; fi
echo 'PASS: download failure, HTTPS validation (isolated stubs)'

# Exercise the real non-dry-run version selector with a fake pyenv, then stop
# before downloading Miniconda. The marker proves which version was selected.
mkdir -p "$HOME/.pyenv"
export TEST_VERSION_LOG="$scratch/version-log"
cat > "$scratch/bin/pyenv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'install --list' ]]; then
  printf '  3.9.9\n  3.9.10\n  3.14.2\n  3.15.0rc1\n'
elif [[ "$1 $2" == 'init -' ]]; then
  :
else
  printf '%s\n' "$*" >> "$TEST_VERSION_LOG"
fi
EOF
chmod +x "$scratch/bin/pyenv"
if inst --python > "$scratch/python" 2>&1; then fail 'expected Miniconda download failure'; fi
grep -q '^install -s 3.14.2$' "$TEST_VERSION_LOG" || fail 'python latest'
grep -q '^global 3.14.2$' "$TEST_VERSION_LOG" || fail 'python global'
: > "$TEST_VERSION_LOG"
if inst --python --python-version 3.9 > /dev/null 2>&1; then :; fi
grep -q '^install -s 3.9.10$' "$TEST_VERSION_LOG" || fail 'python 3.9 prefix'
env_file="$HOME/.config/inst/env.sh"
grep -q '# >>> inst:pyenv' "$env_file" || fail 'pyenv env block'
[[ "$(grep -c '# >>> inst:pyenv' "$env_file")" == 1 ]] || fail 'env block duplicated'
[[ "$(grep -c 'inst/env.sh' "$INST_SHELL_RC")" == 1 ]] || fail 'rc hook duplicated'
sh -n "$env_file" || fail 'env.sh not POSIX sh'
echo 'PASS: non-dry-run Python version selection and idempotent env blocks'

if inst --self-update > "$scratch/self-update" 2>&1; then fail 'self-update accepted without local path'; fi
grep -q '只支持本地文件模式' "$scratch/self-update" || fail 'self-update message'
export INST_INSTALLER_PATH="$scratch/local-installer"
printf '#!/bin/bash\necho original\n' > "$INST_INSTALLER_PATH"
cp "$INST_INSTALLER_PATH" "$scratch/original"
inst --self-update --dry-run > "$scratch/update-plan"
cmp "$INST_INSTALLER_PATH" "$scratch/original"
test -z "$(find "$scratch" -name 'local-installer.tmp.*' -print)"
mkdir -p "$scratch/curlbin"
cat > "$scratch/curlbin/curl" <<'EOF'
#!/usr/bin/env bash
out=''; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
printf '%s' "$FAKE_REMOTE" > "$out"
EOF
chmod +x "$scratch/curlbin/curl"
printf '#!/bin/bash\nINST_VERSION="1.0.0"\n' > "$INST_INSTALLER_PATH"
FAKE_REMOTE='not a script' PATH="$scratch/curlbin:$PATH" inst --self-update > "$scratch/update-bad" 2>&1 && fail 'invalid update accepted'
grep -q 'INST_VERSION="1.0.0"' "$INST_INSTALLER_PATH" || fail 'invalid update replaced target'
FAKE_REMOTE=$'#!/bin/bash\nINST_VERSION="9.0.0"\n' PATH="$scratch/curlbin:$PATH" inst --self-update > "$scratch/update-ok" 2>&1
grep -q 'INST_VERSION="9.0.0"' "$INST_INSTALLER_PATH" || fail 'self-update did not replace'
grep -q 'INST_VERSION="1.0.0"' "$INST_INSTALLER_PATH.bak" || fail 'self-update backup'
unset INST_INSTALLER_PATH
export TEST_OS=Darwin TEST_ARCH=arm64
export INST_DESKTOP_CLAUDE_URL=https://example.invalid/claude.dmg
inst --desktop --dry-run --desktop-dir "$scratch/Apps" > "$scratch/desktop-plan"
grep -q 'hdiutil attach' "$scratch/desktop-plan" || fail 'desktop dmg plan'
test ! -e "$scratch/Apps" || fail 'desktop dry-run created dir'
unset INST_DESKTOP_CLAUDE_URL
inst --desktop --dry-run --desktop-dir "$scratch/Apps" > "$scratch/desktop-default" 2>&1
grep -q 'darwin/universal/RELEASES.json' "$scratch/desktop-default" || fail 'claude mac feed'
grep -q 'ditto -x -k' "$scratch/desktop-default" || fail 'claude mac zip plan'
grep -q 'codex-app-prod/Codex.dmg' "$scratch/desktop-default" || fail 'codex mac dmg'
test ! -e "$scratch/Apps" || fail 'desktop default dry-run created dir'
echo 'PASS: self-update and desktop dry-run do not execute download/install commands'

rm -f "$scratch/bin/curl"
export TEST_OS=Linux TEST_ARCH=x86_64
mkdir -p "$scratch/empty-bin"
ln -s "$scratch/bin/uname" "$scratch/empty-bin/uname"
PATH="$scratch/empty-bin:/usr/bin:/bin" inst --mirrors --npm-registry https://registry.invalid > "$scratch/mirror" 2>&1 \
  || { cat "$scratch/mirror"; fail 'npmrc fallback'; }
grep -qx 'registry=https://registry.invalid' "$HOME/.npmrc" || fail 'npmrc not written'
if inst --mirrors --npm-registry http://registry.invalid > "$scratch/insecure-mirror" 2>&1; then fail 'insecure mirror accepted'; fi
grep -q 'NPM_REGISTRY 必须是 HTTPS URL' "$scratch/insecure-mirror" || fail 'insecure mirror message'
if inst --mirrors --system-mirror tuna > "$scratch/sys" 2>&1; then :; fi
if grep -q 'sed -E -i' "$scratch/sys"; then fail 'system mirror applied without confirmation'; fi
echo 'PASS: mirror fallbacks and confirmation'

# Endpoint configuration merges into existing agent config files.
if command -v node > /dev/null 2>&1 || command -v python3 > /dev/null 2>&1; then
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  printf '{"theme":"dark","env":{"KEEP":"1"}}\n' > "$HOME/.claude/settings.json"
  printf 'model = "gpt-5"\napproval_policy = "never"\n\n[model_providers.inst]\nbase_url = "https://old"\n\n[mcp_servers.x]\ncommand = "x"\n' > "$HOME/.codex/config.toml"
  INST_API_KEY=sk-test inst --endpoint claude,codex,gemini,pi --base-url https://api.example.com/v1/ --model m1 > "$scratch/endpoint" 2>&1 \
    || { cat "$scratch/endpoint"; fail 'endpoint config'; }
  grep -q '"theme": "dark"' "$HOME/.claude/settings.json" || fail 'claude settings lost'
  grep -q '"KEEP": "1"' "$HOME/.claude/settings.json" || fail 'claude env lost'
  grep -q '"ANTHROPIC_BASE_URL": "https://api.example.com/v1"' "$HOME/.claude/settings.json" || fail 'claude base url'
  grep -q '"ANTHROPIC_AUTH_TOKEN": "sk-test"' "$HOME/.claude/settings.json" || fail 'claude token'
  [[ "$(head -n 1 "$HOME/.codex/config.toml")" == 'model_provider = "inst"' ]] || fail 'codex provider not top-level'
  [[ "$(grep -c '^\[model_providers.inst\]' "$HOME/.codex/config.toml")" == 1 ]] || fail 'codex provider duplicated'
  grep -q '^base_url = "https://api.example.com/v1"$' "$HOME/.codex/config.toml" || fail 'codex base url'
  grep -q '^\[mcp_servers.x\]' "$HOME/.codex/config.toml" || fail 'codex other tables lost'
  grep -q '^approval_policy = "never"' "$HOME/.codex/config.toml" || fail 'codex settings lost'
  grep -q 'INST_CODEX_API_KEY' "$env_file" || fail 'codex key env'
  grep -qx 'GOOGLE_GEMINI_BASE_URL=https://api.example.com/v1' "$HOME/.gemini/.env" || fail 'gemini env'
  grep -q '"baseUrl": "https://api.example.com/v1"' "$HOME/.pi/agent/models.json" || fail 'pi models.json'
  grep -q '"selectedType": "gemini-api-key"' "$HOME/.gemini/settings.json" || fail 'gemini auth type'
  if inst --endpoint claude --base-url http://insecure.example > /dev/null 2>&1; then fail 'insecure endpoint accepted'; fi
  echo 'PASS: endpoint configuration merges existing files'
fi
