#!/usr/bin/env bash
# Gates for the experimental config. Run from the config root via `just check`.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

nvim_bin="${NVIM_BIN:-$HOME/.local/share/nvim-versions/current/bin/nvim}"
status=0

say() {
  local kind=$1 message=$2
  case $kind in
    PASS) printf '  \033[32mPASS\033[0m  %s\n' "$message" ;;
    SKIP) printf '  \033[33mSKIP\033[0m  %s\n' "$message" ;;
    FAIL) printf '  \033[31mFAIL\033[0m  %s\n' "$message"; status=1 ;;
  esac
}

mapfile -t files < <(find init.lua lua -name '*.lua' 2>/dev/null | sort)
if ((${#files[@]} == 0)); then
  echo "no Lua files found" >&2
  exit 1
fi

if luac -p "${files[@]}" 2>/tmp/luac.$$; then
  say PASS "syntax (${#files[@]} files)"
else
  say FAIL "syntax: $(head -3 /tmp/luac.$$)"
fi
rm -f /tmp/luac.$$

# LuaCATS annotations are type information, not prose, so they are excluded.
read -r comments code < <(
  awk '
    /^[[:space:]]*---@/ { next }
    /^[[:space:]]*--/   { comments++; next }
    /[^[:space:]]/      { code++ }
    END { print comments + 0, code + 0 }
  ' "${files[@]}"
)
if ((comments * 10 <= code)); then
  say PASS "comment budget ($comments prose / $code code)"
else
  say FAIL "comments exceed 10% of code ($comments / $code)"
fi

if command -v stylua >/dev/null; then
  if stylua --check "${files[@]}" >/dev/null 2>&1; then
    say PASS "stylua"
  else
    say FAIL "stylua (run: stylua ${files[*]})"
  fi
else
  say SKIP "stylua not installed"
fi

if command -v selene >/dev/null; then
  if selene "${files[@]}" >/dev/null 2>&1; then
    say PASS "selene"
  else
    say FAIL "selene (run: selene lua init.lua)"
  fi
else
  say SKIP "selene not installed"
fi

if [[ -x $nvim_bin ]]; then
  smoke=$(NVIM_APPNAME=nvim/experimental "$nvim_bin" --headless \
    -c 'lua require("core.lang").setup(); print("CONFIG_SMOKE_OK")' -c 'qa!' 2>&1)
  if grep -q 'CONFIG_SMOKE_OK' <<<"$smoke" &&
    ! grep -qE 'Error detected|stack traceback|E[0-9]+:' <<<"$smoke"; then
    say PASS "headless smoke start"
  else
    say FAIL "headless smoke start"
    sed 's/^/        /' <<<"$smoke" | head -20
  fi
else
  say FAIL "nvim not found at $nvim_bin (run: just setup-update-nightly)"
fi

exit $status
