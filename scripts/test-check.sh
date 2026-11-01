#!/usr/bin/env sh
# test-check.sh — regression suite for scripts/graft-check.sh
#
# Every case builds a fake `graft` executable in a temp dir, so the default run
# touches no real CLI, no network and no repository. WHEN graft is installed the
# integration cases at the end also exercise the real CLI in a throwaway repo;
# set GRAFT_TEST_NO_CLI=1 to skip them.
#
# Run:  ./scripts/test-check.sh
# Exit: 0 all cases passed (skips allowed); 1 one or more failed.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$SCRIPT_DIR/graft-check.sh"

if [ ! -x "$CHECK" ]; then
  printf 'cannot find executable %s\n' "$CHECK" >&2
  exit 1
fi

case "${1:-}" in
  -h|--help)
    cat >&2 <<'EOF'
usage: test-check.sh

Regression suite for graft-check.sh. Builds synthetic `graft` executables in a
temp dir (no real CLI, no network, no repo writes). When graft is installed, a
final integration section runs it against a throwaway repo; set
GRAFT_TEST_NO_CLI=1 to skip that section.
EOF
    exit 0
    ;;
esac

# Telemetry must never fire from a test run.
export DO_NOT_TRACK=1

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/graft-check-tests.XXXXXX" 2>/dev/null) || {
  printf 'cannot create a temp dir\n' >&2
  exit 1
}
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM

FAKEBIN="$ROOT/bin"
RUN_DIR="$ROOT/repo"
OUT="$ROOT/out.json"
ERROUT="$ROOT/err.txt"
mkdir -p "$FAKEBIN" "$RUN_DIR"

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# fake_graft <check-json> [exit-code] [version]
fake_graft() {
  _fg_json=$1
  _fg_code=${2:-0}
  _fg_ver=${3:-0.28.1}
  {
    printf '#!/bin/sh\n'
    printf 'case "${1:-}" in\n'
    printf '  --version) echo %s ;;\n' "$_fg_ver"
    printf "  check) printf '%%s\\\\n' '%s'; exit %s ;;\n" "$_fg_json" "$_fg_code"
    printf '  *) exit 0 ;;\n'
    printf 'esac\n'
  } > "$FAKEBIN/graft"
  chmod +x "$FAKEBIN/graft"
}

fresh_repo() {
  rm -rf "$RUN_DIR"
  mkdir -p "$RUN_DIR"
}

# put_wiring <json>
put_wiring() {
  mkdir -p "$RUN_DIR/graft/.graph"
  printf '%s' "$1" > "$RUN_DIR/graft/.graph/wiring.json"
}

# check_case <label> <want-exit> [+required-substring | -forbidden-substring]...
check_case() {
  _cc_label=$1
  _cc_want=$2
  shift 2

  set +e
  PATH="$FAKEBIN:/usr/bin:/bin" "$CHECK" "${CASE_REPO:-$RUN_DIR}" > "$OUT" 2> "$ERROUT"
  _cc_code=$?
  set -e

  _cc_bad=0
  if [ "$_cc_code" -ne "$_cc_want" ]; then
    printf 'FAIL  %s: exit %s, want %s\n' "$_cc_label" "$_cc_code" "$_cc_want"
    _cc_bad=1
  fi
  for _cc_pat in "$@"; do
    case "$_cc_pat" in
      +*)
        if ! grep -F -q -- "${_cc_pat#+}" "$OUT"; then
          printf 'FAIL  %s: missing %s\n' "$_cc_label" "${_cc_pat#+}"
          _cc_bad=1
        fi
        ;;
      -*)
        if grep -F -q -- "${_cc_pat#-}" "$OUT"; then
          printf 'FAIL  %s: must not contain %s\n' "$_cc_label" "${_cc_pat#-}"
          _cc_bad=1
        fi
        ;;
    esac
  done

  if [ "$_cc_bad" -eq 0 ]; then
    printf 'ok    %s\n' "$_cc_label"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    if [ -s "$ERROUT" ]; then sed 's/^/      stderr: /' "$ERROUT"; fi
  fi
}

skip_case() {
  printf 'skip  %s\n' "$1"
  SKIP=$((SKIP + 1))
}

# ---------------------------------------------------------------------------
# Payload shorthands
# ---------------------------------------------------------------------------
CTX_OK='{"ok":true,"missing":false,"contentDrift":[],"removed":[],"coverage":[],"indexDrift":[]}'
CTX_MISSING='{"ok":false,"missing":true,"contentDrift":[],"removed":[],"coverage":[],"indexDrift":[]}'
CTX_DRIFT='{"ok":false,"missing":false,"contentDrift":[{"file":"src/a.ts"}],"removed":[],"coverage":[],"indexDrift":[]}'

printf '== graft-check.sh regression suite ==\n'

# 1. Both layers current -> fresh and usable.
fresh_repo
fake_graft "{\"context\":$CTX_OK,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0,\"nodes\":42}}"
check_case 'fresh: both layers current' 0 \
  '+"status":"fresh"' '+"usable":true' '+"freshness":"fresh"' '+"staleLayer":null' '+"nodes":42' '+"nodesSource":"cli"'

# 2. Structural-only build (plain `graft build`) -> usable, concept layer absent.
fresh_repo
fake_graft "{\"context\":$CTX_MISSING,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0,\"nodes\":8}}"
check_case 'structural_only: no --deep layer' 0 \
  '+"status":"structural_only"' '+"usable":true' '+"deepLayer":"missing"' '+"nodes":8'

# 3. Empty graph -> needs_initialization even when both layers claim ok.
fresh_repo
fake_graft "{\"context\":$CTX_OK,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0,\"nodes\":0}}"
check_case 'needs_initialization: nodes=0' 2 \
  '+"status":"needs_initialization"' '+"nodes":0' '+"usable":false'

# 4. No graph at all (graph null) -> needs_initialization.
fresh_repo
fake_graft "{\"context\":$CTX_MISSING,\"graph\":null}" 1
check_case 'needs_initialization: graph null' 2 \
  '+"status":"needs_initialization"' '+"nodes":null'

# 5. Deep layer drifted, wiring current -> stale, layer=context.
fresh_repo
fake_graft "{\"context\":$CTX_DRIFT,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0,\"nodes\":8}}" 1
check_case 'stale: deep layer drifted' 1 \
  '+"status":"stale"' '+"staleLayer":"context"' '+"usable":false' '+--deep'

# 6. Wiring drifted, no deep layer -> stale, layer=graph.
fresh_repo
fake_graft "{\"context\":$CTX_MISSING,\"graph\":{\"ok\":false,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[{\"file\":\"src/a.ts\"}],\"stale\":[],\"pending\":0,\"nodes\":8}}" 1
check_case 'stale: wiring drifted' 1 \
  '+"status":"stale"' '+"staleLayer":"graph"'

# 7. Both layers drifted -> stale, layer=both.
fresh_repo
fake_graft "{\"context\":$CTX_DRIFT,\"graph\":{\"ok\":false,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[{\"file\":\"src/a.ts\"}],\"stale\":[],\"pending\":0,\"nodes\":8}}" 1
check_case 'stale: both layers drifted' 1 \
  '+"status":"stale"' '+"staleLayer":"both"'

# 8-10. Untrustworthy node counts from the CLI -> indeterminate, never usable.
for _bad in null -1 1.5; do
  fresh_repo
  fake_graft "{\"context\":$CTX_MISSING,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0,\"nodes\":$_bad}}"
  check_case "indeterminate: CLI nodes=$_bad" 3 \
    '+"status":"indeterminate"' '+"usable":false' '+"nodes":null' '+"nodesSource":"unknown"'
done

# 11. Pre-0.28 payload without graph.nodes, wiring supplies the count.
fresh_repo
put_wiring '{"meta":{"nodeCount":12,"edgeCount":5}}'
fake_graft "{\"context\":$CTX_MISSING,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0}}" 0 0.10.1
check_case 'wiring fallback: nodes from wiring.json' 0 \
  '+"status":"structural_only"' '+"nodes":12' '+"nodesSource":"wiring.json"'

# 12. Wiring nodeCount is null: the neighbouring edgeCount must not be borrowed.
fresh_repo
put_wiring '{"meta":{"nodeCount":null,"edgeCount":12}}'
fake_graft "{\"context\":$CTX_MISSING,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0}}" 0 0.10.1
check_case 'wiring fallback: null nodeCount is not edgeCount' 3 \
  '+"status":"indeterminate"' '-"nodes":12'

# 13. Fractional wiring nodeCount must not be truncated to an integer.
fresh_repo
put_wiring '{"meta":{"nodeCount":1.5}}'
fake_graft "{\"context\":$CTX_MISSING,\"graph\":{\"ok\":true,\"missing\":false,\"added\":[],\"removed\":[],\"changed\":[],\"stale\":[],\"pending\":0}}" 0 0.10.1
check_case 'wiring fallback: fractional nodeCount rejected' 3 \
  '+"status":"indeterminate"' '-"nodes":1'

# 14. graph:null must not borrow a leftover wiring count.
fresh_repo
put_wiring '{"meta":{"nodeCount":12}}'
fake_graft "{\"context\":$CTX_MISSING,\"graph\":null}" 1
check_case 'no graph: leftover wiring is ignored' 2 \
  '+"status":"needs_initialization"' '+"nodes":null' '-"nodes":12'

# 15. Bad path is an error, not a verdict.
fresh_repo
fake_graft "{\"context\":$CTX_MISSING,\"graph\":null}" 1
CASE_REPO="$ROOT/definitely-not-here" check_case 'bad path' 12 '+"error":"bad_path"'
CASE_REPO=

# 16. No graft on PATH -> graft_not_found.
NONBIN="$ROOT/nonbin"
mkdir -p "$NONBIN"
printf '#!/bin/sh\nexit 1\n' > "$NONBIN/npm"
chmod +x "$NONBIN/npm"
set +e
PATH="$NONBIN:/usr/bin:/bin" "$CHECK" "$RUN_DIR" > "$OUT" 2> "$ERROUT"
_code=$?
set -e
if [ "$_code" -eq 10 ] && grep -F -q '"error":"graft_not_found"' "$OUT"; then
  printf 'ok    %s\n' 'no graft on PATH'
  PASS=$((PASS + 1))
else
  printf 'FAIL  no graft on PATH: exit %s\n' "$_code"
  FAIL=$((FAIL + 1))
fi

# 17. Unparseable check output -> error, not a guessed verdict.
fresh_repo
fake_graft 'not-json-at-all' 0
check_case 'unparseable check output' 11 '+"error":"unparseable_json"'

# 18. --help exits 0 and prints usage.
set +e
"$CHECK" --help > "$OUT" 2> "$ERROUT"
_code=$?
set -e
if [ "$_code" -eq 0 ]; then
  printf 'ok    %s\n' '--help'
  PASS=$((PASS + 1))
else
  printf 'FAIL  --help: exit %s\n' "$_code"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Integration: the real CLI, in a throwaway repo
# ---------------------------------------------------------------------------
printf '\n== integration (real graft CLI) ==\n'

if [ "${GRAFT_TEST_NO_CLI:-0}" = 1 ]; then
  skip_case 'real CLI integration (GRAFT_TEST_NO_CLI=1)'
elif ! command -v graft >/dev/null 2>&1; then
  skip_case 'real CLI integration (graft not installed)'
else
  REAL="$ROOT/real-repo"
  mkdir -p "$REAL/src"
  (
    cd "$REAL" || exit 1
    printf 'export function alpha(x: string): string { return x; }\n' > src/a.ts
    printf 'export function beta(): void {}\n' > src/b.ts
  )
  if graft build "$REAL" >/dev/null 2>&1; then
    set +e
    "$CHECK" "$REAL" > "$OUT" 2> "$ERROUT"
    _code=$?
    set -e
    if [ "$_code" -eq 0 ] && grep -F -q '"status":"structural_only"' "$OUT"; then
      printf 'ok    %s\n' 'real CLI: plain build is structural_only'
      PASS=$((PASS + 1))
    else
      printf 'FAIL  real CLI: plain build expected structural_only, exit %s\n' "$_code"
      FAIL=$((FAIL + 1))
      sed 's/^/      /' "$OUT"
    fi

    # An edit with no refresh must read as stale.
    printf '\nexport const gamma = 1;\n' >> "$REAL/src/a.ts"
    set +e
    "$CHECK" "$REAL" > "$OUT" 2> "$ERROUT"
    _code=$?
    set -e
    if [ "$_code" -eq 1 ] && grep -F -q '"status":"stale"' "$OUT"; then
      printf 'ok    %s\n' 'real CLI: edited source is stale'
      PASS=$((PASS + 1))
    else
      printf 'FAIL  real CLI: edited source expected stale, exit %s\n' "$_code"
      FAIL=$((FAIL + 1))
      sed 's/^/      /' "$OUT"
    fi
  else
    skip_case 'real CLI integration (graft build failed)'
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0