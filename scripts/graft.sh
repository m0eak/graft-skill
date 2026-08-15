#!/usr/bin/env sh
# Minimal, argument-preserving Graft CLI wrapper for Skill users.
set -eu

if command -v graft >/dev/null 2>&1; then
  exec graft "$@"
fi

NPM_PREFIX=""
if command -v npm >/dev/null 2>&1; then
  NPM_PREFIX="$(npm prefix -g 2>/dev/null || true)"
fi
if [ -n "$NPM_PREFIX" ] && [ -x "$NPM_PREFIX/bin/graft" ]; then
  exec "$NPM_PREFIX/bin/graft" "$@"
fi

printf '%s\n' \
  'Graft CLI was not found. Install it only after the user confirms:' \
  '  npm install -g @nanonets/graft' \
  'Requires Node.js >=20. Then retry the requested command.' >&2
exit 127
