#!/usr/bin/env sh
# graft-runtime.sh — discover the installed Graft runtime WITHOUT hard-coding
# versions or the supported-extension list.
#
# Modes:
#   --shell   print sh-safe `KEY='value'` assignments (eval this to load vars)
#   --json    print one machine-parseable JSON document
#   --help    usage
#
# Resolved values:
#   GRAFT_BIN                    graft executable (PATH first, then npm prefix -g)
#   GRAFT_RUNTIME_VERSION        `graft --version` output, sanitized, or empty
#   GRAFT_PKG_DIR                the @nanonets/graft package directory, or empty
#   GRAFT_SUPPORTED_SET_VERSION  package.json "version" (source version of the
#                                CODE_EXTENSIONS set baked into the build), or empty
#   GRAFT_CODE_EXTENSIONS        space-separated extension list, or empty
#   GRAFT_SUPPORT_DISCOVERY      ok | not_installed | package_not_found | extract_failed
#
# Package location, in order (handles PATH vs npm global-dir differences):
#   1. npm root -g               -> $root/@nanonets/graft
#   2. graft bin symlink target  -> real dist/cli.js, walk up to package root
#   3. npm prefix -g             -> $prefix/lib/node_modules/@nanonets/graft
#
# CODE_EXTENSIONS extraction (heuristic boundaries):
#   - In @nanonets/graft 0.10.1 the constant is only in dist/context/build.js as
#     `export const CODE_EXTENSIONS = [ ... ];`. It is NOT re-exported from a
#     stable separate module, so the build JS is the only reliable source.
#   - A state machine reads that array literal and keeps only double-quoted
#     tokens matching `^\.[A-Za-z0-9_-]+$`, so comments/other strings inside the
#     literal are NOT mistaken for extensions.
#   - If a future package ships a different layout (minified bundle, renamed
#     constant, TS source only, no dist/), extraction fails and
#     SUPPORT_DISCOVERY=extract_failed. Callers MUST surface this instead of
#     silently falling back to a stale hard-coded list.
#
# This script only reads the installed package and runs `graft --version`
# (read-only). It never writes to any repository.

set -eu

shq() {
  # Single-quote a value so it can be safely eval'd by POSIX sh.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t\r' ' '
}

usage() {
  cat >&2 <<'EOF'
usage: graft-runtime.sh --shell | --json | --help

Discover the installed Graft runtime (binary, CLI version, package dir,
supported-extension set) without hard-coding versions. --shell emits
sh-safe KEY='value' assignments; --json emits one JSON document.
EOF
}

# ---------------------------------------------------------------------------
# 1. Resolve the graft binary (PATH first, then npm prefix -g)
# ---------------------------------------------------------------------------
GRAFT_BIN=""
if command -v graft >/dev/null 2>&1; then
  GRAFT_BIN=$(command -v graft)
elif command -v npm >/dev/null 2>&1; then
  _prefix=$(npm prefix -g 2>/dev/null || true)
  if [ -n "$_prefix" ] && [ -x "$_prefix/bin/graft" ]; then
    GRAFT_BIN="$_prefix/bin/graft"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Runtime version via `graft --version` (read-only, sanitized)
# ---------------------------------------------------------------------------
GRAFT_RUNTIME_VERSION=""
if [ -n "$GRAFT_BIN" ]; then
  _v=$("$GRAFT_BIN" --version 2>/dev/null | head -n 1 || true)
  _v=$(printf '%s' "$_v" | tr -d '[:space:]')
  case "$_v" in
    '') ;;
    *[!0-9A-Za-z.+-]*) ;;
    *) GRAFT_RUNTIME_VERSION="$_v" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Locate the @nanonets/graft package directory
# ---------------------------------------------------------------------------
GRAFT_PKG_DIR=""
command -v npm >/dev/null 2>&1 && NPM_OK=1 || NPM_OK=0

try_pkg() {
  # $1 = candidate package dir; accept only if it carries package.json.
  [ -n "${1:-}" ] || return 0
  [ -f "$1/package.json" ] || return 0
  GRAFT_PKG_DIR="$1"
}

# 3a. npm root -g
if [ "$NPM_OK" = 1 ]; then
  _root=$(npm root -g 2>/dev/null || true)
  try_pkg "$_root/@nanonets/graft"
fi

# 3b. graft bin -> resolve symlink chain -> walk up from dist/cli.js
if [ -z "$GRAFT_PKG_DIR" ] && [ -n "$GRAFT_BIN" ]; then
  _real="$GRAFT_BIN"
  if command -v readlink >/dev/null 2>&1; then
    _t=$(readlink "$GRAFT_BIN" 2>/dev/null || true)
    if [ -n "$_t" ]; then
      case "$_t" in
        /*) _real="$_t" ;;
        *) _real="$(dirname -- "$GRAFT_BIN")/$_t" ;;
      esac
      # normalize parent dir (resolves '..' and symlinked dirs)
      _real_dir=$(CDPATH= cd -- "$(dirname -- "$_real")" 2>/dev/null && pwd -P || true)
      if [ -n "$_real_dir" ]; then
        _real="$_real_dir/$(basename -- "$_real")"
      fi
    fi
  fi
  # dist/cli.js -> package root is two dirname()s up
  try_pkg "$(dirname -- "$(dirname -- "$_real")")"
fi

# 3c. npm prefix -g -> lib/node_modules/@nanonets/graft
if [ -z "$GRAFT_PKG_DIR" ] && [ "$NPM_OK" = 1 ]; then
  _prefix=$(npm prefix -g 2>/dev/null || true)
  try_pkg "$_prefix/lib/node_modules/@nanonets/graft"
fi

# ---------------------------------------------------------------------------
# 4. supported-set version from package.json
# ---------------------------------------------------------------------------
GRAFT_SUPPORTED_SET_VERSION=""
if [ -n "$GRAFT_PKG_DIR" ] && [ -f "$GRAFT_PKG_DIR/package.json" ]; then
  GRAFT_SUPPORTED_SET_VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GRAFT_PKG_DIR/package.json" | head -n 1)
fi

# ---------------------------------------------------------------------------
# 5. CODE_EXTENSIONS extraction from dist/context/build.js
# ---------------------------------------------------------------------------
GRAFT_CODE_EXTENSIONS=""
if [ -n "$GRAFT_PKG_DIR" ] && [ -f "$GRAFT_PKG_DIR/dist/context/build.js" ]; then
  GRAFT_CODE_EXTENSIONS=$(awk '
    function is_ext(t) { return (t ~ /^\.[A-Za-z0-9_-]+$/) }
    BEGIN { on = 0 }
    {
      if (on == 0) {
        if ($0 ~ /CODE_EXTENSIONS[[:space:]]*=[[:space:]]*\[/) { on = 1 }
        else next
      }
      n = split($0, a, "\"")
      for (i = 2; i <= n; i += 2) if (is_ext(a[i])) print a[i]
      if (index($0, "]")) exit
    }
  ' "$GRAFT_PKG_DIR/dist/context/build.js")
  GRAFT_CODE_EXTENSIONS=$(printf '%s' "$GRAFT_CODE_EXTENSIONS" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
fi

# ---------------------------------------------------------------------------
# 6. Discovery verdict
# ---------------------------------------------------------------------------
GRAFT_SUPPORT_DISCOVERY="unknown"
if [ -n "$GRAFT_PKG_DIR" ]; then
  if [ -n "$GRAFT_CODE_EXTENSIONS" ]; then
    GRAFT_SUPPORT_DISCOVERY="ok"
  else
    GRAFT_SUPPORT_DISCOVERY="extract_failed"
  fi
else
  if [ -n "$GRAFT_BIN" ]; then
    GRAFT_SUPPORT_DISCOVERY="package_not_found"
  else
    GRAFT_SUPPORT_DISCOVERY="not_installed"
  fi
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
case "${1:-}" in
  --shell)
    printf 'GRAFT_BIN=%s\n'             "$(shq "$GRAFT_BIN")"
    printf 'GRAFT_RUNTIME_VERSION=%s\n' "$(shq "$GRAFT_RUNTIME_VERSION")"
    printf 'GRAFT_PKG_DIR=%s\n'         "$(shq "$GRAFT_PKG_DIR")"
    printf 'GRAFT_SUPPORTED_SET_VERSION=%s\n' "$(shq "$GRAFT_SUPPORTED_SET_VERSION")"
    printf 'GRAFT_CODE_EXTENSIONS=%s\n' "$(shq "$GRAFT_CODE_EXTENSIONS")"
    printf 'GRAFT_SUPPORT_DISCOVERY=%s\n' "$(shq "$GRAFT_SUPPORT_DISCOVERY")"
    ;;
  --json)
    _bin=$(printf '%s' "$GRAFT_BIN" | json_escape)
    _ver=$(printf '%s' "$GRAFT_RUNTIME_VERSION" | json_escape)
    _pkg=$(printf '%s' "$GRAFT_PKG_DIR" | json_escape)
    _set=$(printf '%s' "$GRAFT_SUPPORTED_SET_VERSION" | json_escape)
    _dis=$(printf '%s' "$GRAFT_SUPPORT_DISCOVERY" | json_escape)
    _ext="null"
    if [ -n "$GRAFT_CODE_EXTENSIONS" ]; then
      _ext="["
      _sep=""
      for _e in $GRAFT_CODE_EXTENSIONS; do
        _ee=$(printf '%s' "$_e" | json_escape)
        _ext="$_ext$_sep\"$_ee\""
        _sep=","
      done
      _ext="$_ext]"
    fi
    printf '{"schema":1,"script":"graft-runtime.sh","graftBin":"%s","runtimeVersion":"%s","packageDir":"%s","supportedSetVersion":"%s","supportedExtensions":%s,"supportDiscovery":"%s"}\n' \
      "$_bin" "$_ver" "$_pkg" "$_set" "$_ext" "$_dis"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
