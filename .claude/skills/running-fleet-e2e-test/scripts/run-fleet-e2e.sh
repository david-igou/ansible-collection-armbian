#!/usr/bin/env bash
#
# run-fleet-e2e.sh — driver for the deterministic six-phase fleet e2e
# (playbooks/tests/test_fleet_e2e.yml). Creates a unique per-run artifact
# directory, tees ansible output, archives the per-board
# /tmp/iter-FLEET-<host>/ dirs back into the run dir for archival, and
# saves the rendered Summary table as a separate file.
#
# Why a wrapper at all: the playbook writes per-board artifacts under
# /tmp/iter-FLEET-<host>/<phase>/ which get overwritten on the next run
# of the same fleet test. The aggregated /tmp/fleet-run-<timestamp>/
# dir is the durable record — copy it / attach it to a PR / read it
# six months later when someone asks "did this board pass on 2026-05-19?"
#
# Usage:
#   .claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh [options] [-- ansible-playbook extras...]
#
# Options:
#   --target-hosts <csv>    Comma-separated inventory hostnames or group
#                           name. Default: 'boards' (the playbook's
#                           default target group).
#   --skip <csv>            Comma-separated phase numbers (0-5) to skip.
#                           Each becomes -e skip_phase_<N>=true. E.g.
#                           --skip 0,1 skips Phase 0 (PoE-down) and
#                           Phase 1 (NFS reset).
#   --run-dir <path>        Override the artifact run directory.
#                           Default: /tmp/fleet-run-<timestamp>.
#   -h | --help             Print usage and exit.
#
# Anything after `--` is passed through to ansible-playbook verbatim.
#
# Examples:
#   # Full fleet
#   .claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh
#
#   # Subset of boards
#   .claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --target-hosts opi5pro-01,rock-5b-01
#
#   # Single-board first run
#   .claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --target-hosts opi5pro-01
#
#   # Skip Phase 0 (PoE-down) and Phase 1 (NFS reset) — already proven
#   .claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --skip 0,1
#
#   # Pass extra knobs through to ansible-playbook
#   .claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh -- -e fleet_phase_5_throttle=1 \
#                                       -e armbian_poe_cycle_delay=45
#
# Artifact layout (per run):
#   /tmp/fleet-run-<timestamp>/
#       meta.txt              invocation metadata
#       e2e.log               full ansible stdout + stderr
#       summary.txt           the Summary table extracted from e2e.log
#       boards/<host>/        snapshot of each board's /tmp/iter-FLEET-<host>/
#
# Exit code: ansible-playbook's exit code.

set -uo pipefail

usage() {
  sed -n '3,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'
}

TARGET_HOSTS=""
SKIP_CSV=""
RUN_DIR=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-hosts)
      TARGET_HOSTS="$2"; shift 2 ;;
    --target-hosts=*)
      TARGET_HOSTS="${1#*=}"; shift ;;
    --skip)
      SKIP_CSV="$2"; shift 2 ;;
    --skip=*)
      SKIP_CSV="${1#*=}"; shift ;;
    --run-dir)
      RUN_DIR="$2"; shift 2 ;;
    --run-dir=*)
      RUN_DIR="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; EXTRA_ARGS=("$@"); break ;;
    *)
      echo "[run-fleet-e2e] unknown option: $1" >&2
      echo "Run with -h for usage." >&2
      exit 2 ;;
  esac
done

# Resolve repo root from this script's location so we can run from
# anywhere (collection root, deeper subdir, an external symlink, ...).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Script lives at .claude/skills/running-fleet-e2e-test/scripts/ — repo
# root is four levels up (scripts/ → skill-dir/ → skills/ → .claude/ → repo).
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
PLAYBOOK="${REPO_ROOT}/playbooks/tests/test_fleet_e2e.yml"

if [[ ! -f "${PLAYBOOK}" ]]; then
  echo "[run-fleet-e2e] playbook not found at ${PLAYBOOK}" >&2
  exit 2
fi

TIMESTAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="/tmp/fleet-run-${TIMESTAMP}"
fi
mkdir -p "${RUN_DIR}/boards"

META_FILE="${RUN_DIR}/meta.txt"
E2E_LOG="${RUN_DIR}/e2e.log"
SUMMARY_FILE="${RUN_DIR}/summary.txt"

# Build -e args from --skip + --target-hosts.
ANSIBLE_VARS=()
if [[ -n "${TARGET_HOSTS}" ]]; then
  ANSIBLE_VARS+=(-e "target_hosts=${TARGET_HOSTS}")
fi
if [[ -n "${SKIP_CSV}" ]]; then
  IFS=',' read -ra SKIP_PHASES <<< "${SKIP_CSV}"
  for p in "${SKIP_PHASES[@]}"; do
    case "$p" in
      0|1|2|3|4|5)
        ANSIBLE_VARS+=(-e "skip_phase_${p}=true") ;;
      *)
        echo "[run-fleet-e2e] --skip: invalid phase '$p' (valid: 0,1,2,3,4,5)" >&2
        exit 2 ;;
    esac
  done
fi

{
  echo "fleet-run-${TIMESTAMP}"
  echo "start:           $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  echo "target_hosts:    ${TARGET_HOSTS:-<default: boards>}"
  echo "skip:            ${SKIP_CSV:-<none>}"
  echo "playbook:        ${PLAYBOOK}"
  echo "extra args:      ${EXTRA_ARGS[*]:-<none>}"
  echo "ansible vars:    ${ANSIBLE_VARS[*]:-<none>}"
  echo "run dir:         ${RUN_DIR}"
} > "${META_FILE}"

echo "[run-fleet-e2e] $(cat "${META_FILE}")"
echo "[run-fleet-e2e] running ansible-playbook (output → ${E2E_LOG})..."

cp "${META_FILE}" "${E2E_LOG}"
echo >> "${E2E_LOG}"

# Run from the repo root so the playbook's relative imports
# (tasks/_lifecycle_set_and_verify.yml, etc.) resolve.
( cd "${REPO_ROOT}" && \
  ansible-playbook "${PLAYBOOK}" \
    "${ANSIBLE_VARS[@]}" \
    "${EXTRA_ARGS[@]}" \
  >> "${E2E_LOG}" 2>&1 )
RC=$?

echo "end (rc=${RC}):   $(date -u +'%Y-%m-%d %H:%M:%S UTC')" >> "${E2E_LOG}"

# Extract the Summary play's debug output into summary.txt. The play
# renders a multi-line msg block; everything between the
# "=== Deterministic fleet test per-phase wall times" header and the
# final ")" closing the parenthetical hint is the table.
awk '
  /=== Deterministic fleet test per-phase wall times/ { in_summary=1 }
  in_summary { print }
  in_summary && /^[[:space:]]*Per-host artefacts:/ { in_summary=0 }
' "${E2E_LOG}" > "${SUMMARY_FILE}"

# If the Summary marker never matched (run aborted before Summary play),
# leave a stub so an operator opening the file gets context rather than
# silent emptiness.
if [[ ! -s "${SUMMARY_FILE}" ]]; then
  printf '(Summary play did not run — fleet test aborted early; see e2e.log)\n' \
    > "${SUMMARY_FILE}"
fi

# Archive per-board artifact directories. Each board's
# /tmp/iter-FLEET-<host>/ holds evidence + timing for that run.
# Use rsync if available so the snapshot is fast + atomic; fall back
# to cp -r otherwise.
shopt -s nullglob
HOST_DIRS=( /tmp/iter-FLEET-* )
shopt -u nullglob
if (( ${#HOST_DIRS[@]} > 0 )); then
  for d in "${HOST_DIRS[@]}"; do
    host="$(basename "$d" | sed 's/^iter-FLEET-//')"
    dest="${RUN_DIR}/boards/${host}"
    mkdir -p "${dest}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${d}/" "${dest}/"
    else
      cp -r "${d}/." "${dest}/"
    fi
  done
else
  echo "(no /tmp/iter-FLEET-* dirs found — playbook may not have reached any phase)" \
    > "${RUN_DIR}/boards/.empty"
fi

echo
echo "== fleet-run-${TIMESTAMP} artifacts =="
echo "run dir:  ${RUN_DIR}"
echo "log:      ${E2E_LOG}"
echo "summary:  ${SUMMARY_FILE}"
echo "boards/:  $(ls -1 "${RUN_DIR}/boards" 2>/dev/null | wc -l) host snapshot(s)"
echo
echo "----- summary.txt -----"
cat "${SUMMARY_FILE}"
echo "-----------------------"
exit "${RC}"
