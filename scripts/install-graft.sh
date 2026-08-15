#!/usr/bin/env sh
# Run only after explicit user confirmation. Installs the official Graft npm CLI.
set -eu

if ! command -v npm >/dev/null 2>&1; then
  echo 'npm is required but was not found. Install Node.js >=20 and npm first.' >&2
  exit 1
fi

NODE_VERSION="$(node --version 2>/dev/null || true)"
case "$NODE_VERSION" in
  v2[0-9].*|v[3-9][0-9].*) ;;
  *)
    echo "Node.js >=20 is required; detected ${NODE_VERSION:-none}." >&2
    exit 1
    ;;
esac

npm install -g @nanonets/graft
graft --version
