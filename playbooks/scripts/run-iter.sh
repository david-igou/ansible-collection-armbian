#!/usr/bin/env bash
#
# run-iter.sh — driver for hardware-E2E iteration runs (issue #38 and
# successors). Captures per-iter artifacts in a unique directory and
# posts a single, indexable GitHub issue comment with both logs inlined.
#
# Why a wrapper at all: prior iter runs shared one serial-log path
# (/tmp/serial-<host>.log on the serial host), which means the
# residual-socat / out-of-band-write traffic could clobber later runs'
# data. Per-iter naming (-e _serial_log=/tmp/serial-iter-<N>.log)
# makes settings-vs-output comparisons trivial and eliminates
# cross-run interference.
#
# Usage:
#   playbooks/scripts/run-iter.sh <iter-number> [-- ansible-playbook extras…]
#
# Environment overrides (all optional):
#   ISSUE_NUMBER          GitHub issue to comment on (default: 38)
#   HOST_LIMIT            --limit value (default: opi5pro-01.igou.systems)
#   CAPTURE_SERIAL        1 / 0 — start socat capture and slurp the log
#                         (default: 1). Set to 0 when the serial UART is
#                         physically inaccessible (e.g. a stacked PoE HAT
#                         covers the GPIO pins). With CAPTURE_SERIAL=0:
#                         ansible runs without -e capture_serial=true and
#                         the slurp/comment-section steps are skipped.
#   SERIAL_HOST           ansible host where socat ran (default: localhost)
#   SERIAL_REMOTE_USER    user for the slurp ssh (default: igou)
#   POST_COMMENT          1 to post / 0 to skip the gh comment (default: 1)
#
# Example — iter 16 with the standard verbose + 30 s drain settings:
#   playbooks/scripts/run-iter.sh 16 \
#     -- -e pxelinux_verbose=true -e poe_cycle_delay=30
#
# Example — iter 43, no serial (HAT blocks the UART):
#   CAPTURE_SERIAL=0 playbooks/scripts/run-iter.sh 43 -- -e poe_cycle_delay=30
#
# Artifact layout (per iter):
#   /tmp/iter-<N>/
#       meta.txt                 invocation metadata
#       e2e.log                  full ansible stdout + stderr
#       serial.log               raw serial trace from serial_host
#                                (only when CAPTURE_SERIAL=1)
#       serial-clean.log         control-char-stripped + ANSI-stripped copy
#                                (only when CAPTURE_SERIAL=1)
#       comment.md               body posted to GitHub
#
# Exit code: ansible-playbook's exit code (so iter chaining can short-
# circuit on failure if desired).

set -uo pipefail

ITER="${1:?usage: $0 <iter-number> [-- ansible-playbook extras...]}"
shift
[[ "${1:-}" == "--" ]] && shift

ISSUE_NUMBER="${ISSUE_NUMBER:-38}"
HOST_LIMIT="${HOST_LIMIT:-opi5pro-01.igou.systems}"
CAPTURE_SERIAL="${CAPTURE_SERIAL:-1}"
SERIAL_HOST="${SERIAL_HOST:-localhost}"
SERIAL_REMOTE_USER="${SERIAL_REMOTE_USER:-igou}"
POST_COMMENT="${POST_COMMENT:-1}"

ITER_DIR="/tmp/iter-${ITER}"
mkdir -p "${ITER_DIR}"

E2E_LOG="${ITER_DIR}/e2e.log"
META_FILE="${ITER_DIR}/meta.txt"
SERIAL_REMOTE_PATH="/tmp/serial-iter-${ITER}.log"
SERIAL_LOCAL="${ITER_DIR}/serial.log"
SERIAL_CLEAN="${ITER_DIR}/serial-clean.log"
COMMENT_FILE="${ITER_DIR}/comment.md"

ARGS=("$@")
{
  date -u +"iter ${ITER} start %Y-%m-%d %H:%M:%S UTC"
  echo "limit:           ${HOST_LIMIT}"
  echo "extra args:      ${ARGS[*]}"
  if [ "${CAPTURE_SERIAL}" = "1" ]; then
    echo "serial_host:     ${SERIAL_HOST}"
    echo "serial log path: ${SERIAL_REMOTE_PATH} (on ${SERIAL_HOST})"
  else
    echo "serial capture:  disabled (CAPTURE_SERIAL=0)"
  fi
  echo "issue:           #${ISSUE_NUMBER}"
} > "${META_FILE}"

cp "${META_FILE}" "${E2E_LOG}"
echo >> "${E2E_LOG}"

# Build the playbook's serial-related extra-vars conditionally. With
# CAPTURE_SERIAL=0 the playbook's default (capture_serial: false)
# applies and the serial-capture pre-flight + cleanup-stop blocks
# skip cleanly via their `when: capture_serial | bool` guards.
if [ "${CAPTURE_SERIAL}" = "1" ]; then
  SERIAL_VARS=(-e capture_serial=true -e "_serial_log=${SERIAL_REMOTE_PATH}")
else
  SERIAL_VARS=(-e capture_serial=false)
fi

ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit "${HOST_LIMIT}" \
  "${SERIAL_VARS[@]}" \
  -e armbian_default_password=1234 \
  "${ARGS[@]}" \
  >> "${E2E_LOG}" 2>&1
RC=$?

date -u +"iter ${ITER} end (rc=${RC}) %Y-%m-%d %H:%M:%S UTC" >> "${E2E_LOG}"

if [ "${CAPTURE_SERIAL}" = "1" ]; then
  # Slurp the serial log back from serial_host. Default is
  # `localhost`, which in this devcontainer's inventory has
  # ansible_host=localhost ansible_user=igou — and SSH from the
  # container falls through to the actual host machine via the
  # forwarded SSH_AUTH_SOCK. Use BatchMode so a missing key fails
  # fast rather than hanging on a prompt.
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "${SERIAL_REMOTE_USER}@${SERIAL_HOST}" \
      "cat ${SERIAL_REMOTE_PATH} 2>/dev/null" \
      > "${SERIAL_LOCAL}" 2>/dev/null \
    || echo "(serial slurp from ${SERIAL_REMOTE_USER}@${SERIAL_HOST}:${SERIAL_REMOTE_PATH} failed)" \
         > "${SERIAL_LOCAL}"

  # Strip non-printable bytes + ANSI color codes for inline display.
  # tr first (eats raw escapes), sed second (cleans up the resulting
  # `?[…m` strings produced by tr's escape replacement).
  LC_ALL=C tr -c '\11\12\15\40-\176' '?' < "${SERIAL_LOCAL}" \
    | sed -E 's/\?\[[0-9;]*m//g' \
    > "${SERIAL_CLEAN}"
fi

# GitHub comment body. Trim each log if it's > ~25 KB so the
# 65 KB comment limit isn't blown by a single verbose-mode boot.
truncate_for_inline() {
  local file="$1" max_bytes="$2"
  local size
  size=$(stat -c%s "$file")
  if [ "$size" -le "$max_bytes" ]; then
    cat "$file"
    return
  fi
  local half=$((max_bytes / 2))
  head -c "$half" "$file"
  printf '\n[…trimmed %d bytes from middle; full at %s…]\n' \
    "$((size - max_bytes))" "$file"
  tail -c "$half" "$file"
}

{
  printf '**Iteration %s** — `%s`\n\n' "${ITER}" "$(date -u +'%Y-%m-%d %H:%M UTC')"
  echo "**Configuration**:"
  echo
  echo '```'
  cat "${META_FILE}"
  echo '```'
  echo
  echo "**PLAY RECAP**:"
  echo
  echo '```'
  grep -A1 "PLAY RECAP" "${E2E_LOG}" | tail -2 || echo "(not found)"
  echo '```'
  echo
  printf '<details><summary>e2e ansible run log (%d lines, %d bytes)</summary>\n\n' \
    "$(wc -l < "${E2E_LOG}")" "$(stat -c%s "${E2E_LOG}")"
  echo '```'
  truncate_for_inline "${E2E_LOG}" 30000
  echo '```'
  echo "</details>"
  if [ "${CAPTURE_SERIAL}" = "1" ]; then
    echo
    printf '<details><summary>serial trace (%d lines, %d bytes; ctrl-chars + ANSI codes stripped)</summary>\n\n' \
      "$(wc -l < "${SERIAL_CLEAN}")" "$(stat -c%s "${SERIAL_CLEAN}")"
    echo '```'
    truncate_for_inline "${SERIAL_CLEAN}" 25000
    echo '```'
    echo "</details>"
  fi
} > "${COMMENT_FILE}"

if [ "${POST_COMMENT}" = "1" ]; then
  if gh issue comment "${ISSUE_NUMBER}" --body-file "${COMMENT_FILE}" >/dev/null 2>&1; then
    echo "[run-iter] posted comment to issue #${ISSUE_NUMBER}"
  else
    echo "[run-iter] failed to post comment; body saved at ${COMMENT_FILE}"
  fi
fi

echo
echo "== iter ${ITER} artifacts =="
ls -la "${ITER_DIR}"
exit "${RC}"
