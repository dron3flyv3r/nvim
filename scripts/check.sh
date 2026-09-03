#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
status=0
mapfile -d '' lua_files < <(find lua scripts tests -type f -name '*.lua' -print0)

say() {
  printf '%-12s %s\n' "$1" "$2"
}

if command -v luac >/dev/null 2>&1; then
  syntax_status=0
  for file in "${lua_files[@]}"; do
    luac -p "$file" || syntax_status=1
  done
  if [[ $syntax_status == 0 ]]; then
    say PASS "Lua syntax"
  else
    say FAIL "Lua syntax"
    status=1
  fi
else
  say FAIL "luac is required"
  status=1
fi

read -r comment_lines code_lines < <(
  awk '
    /^[[:space:]]*--/ { comments++ }
    !/^[[:space:]]*(--|$)/ { code++ }
    END { print comments, code }
  ' "${lua_files[@]}"
)
if ((comment_lines * 4 <= code_lines)); then
  say PASS "comment budget ($comment_lines comments / $code_lines code)"
else
  say FAIL "comments exceed 25% of code ($comment_lines / $code_lines)"
  status=1
fi

optional_check() {
  local tool=$1
  shift
  local binary
  binary=$(command -v "$tool" 2>/dev/null || true)
  if [[ -z $binary ]]; then
    local mason_binary="${XDG_DATA_HOME:-${HOME}/.local/share}/nvim/mason/bin/$tool"
    if [[ -x $mason_binary ]]; then binary=$mason_binary; fi
  fi

  if [[ -n $binary ]]; then
    if "$binary" "$@"; then
      say PASS "$tool"
    else
      say FAIL "$tool"
      status=1
    fi
  elif [[ ${NVIM_CONFIG_STRICT:-0} == 1 ]]; then
    say FAIL "$tool is required in strict mode"
    status=1
  else
    say SKIP "$tool is not installed (required in strict mode)"
  fi
}

optional_check stylua --check init.lua lua scripts tests
optional_check selene lua scripts tests

check_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nvim-config-check.XXXXXX") || exit 1
trap 'rm -rf "$check_tmp"' EXIT

if env XDG_CACHE_HOME="$check_tmp/cache" XDG_STATE_HOME="$check_tmp/state" \
  nvim --headless -i NONE "+luafile scripts/smoke.lua" +qa >"$check_tmp/nvim.log" 2>&1; then
  if grep -Eq 'Error detected|stack traceback|Vim:E[0-9]+' "$check_tmp/nvim.log" \
    || ! grep -q 'CONFIG_SMOKE_OK' "$check_tmp/nvim.log"; then
    say FAIL "Neovim reported an asynchronous startup error"
    sed -n '1,160p' "$check_tmp/nvim.log"
    status=1
  else
    say PASS "Neovim startup and smoke checks"
  fi
else
  say FAIL "Neovim startup or smoke checks"
  sed -n '1,160p' "$check_tmp/nvim.log"
  status=1
fi

exit "$status"
