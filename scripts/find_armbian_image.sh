#!/bin/bash
# Queries dl.armbian.com and prints the URL of the latest image for a board.
#
# Usage:
#   ./find_armbian_image.sh --board <dl_dir> [--release <release>] [--variant <variant>]
#
# Examples:
#   ./find_armbian_image.sh --board rock-5b
#   ./find_armbian_image.sh --board orangepi5-pro --release noble --variant minimal
#
# Board dl_dir values (subdirectory at dl.armbian.com):
#   orange-pi-5       → orangepi5
#   orange-pi-5-pro   → orangepi5-pro
#   orange-pi-5-max   → orangepi5-max
#   rock-5b           → rock-5b
#   rock-5a           → rock-5a

set -euo pipefail

BOARD=""
RELEASE="bookworm"
VARIANT="server"
BASE_URL="https://dl.armbian.com"

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --board)   BOARD="$2";   shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -z "${BOARD}" ]] && { echo "ERROR: --board is required" >&2; usage; }

DIR_URL="${BASE_URL}/${BOARD}/"

LISTING=$(curl -sf "${DIR_URL}") || {
    echo "ERROR: Could not fetch ${DIR_URL}" >&2
    echo "Check that the board directory name is correct." >&2
    exit 1
}

# Try preferred variant + release, fall back to release only
MATCH=""
for FILTER in "${VARIANT}" ""; do
    MATCH=$(echo "${LISTING}" \
        | grep -oP 'Armbian[^"]+\.img\.xz' \
        | grep -i "${RELEASE}" \
        | { [[ -n "${FILTER}" ]] && grep -i "${FILTER}" || cat; } \
        | sort -r \
        | head -1 || true)
    [[ -n "${MATCH}" ]] && break
done

if [[ -z "${MATCH}" ]]; then
    echo "ERROR: No image found at ${DIR_URL} matching release=${RELEASE}" >&2
    echo "" >&2
    echo "Available images at ${DIR_URL}:" >&2
    echo "${LISTING}" | grep -oP 'Armbian[^"]+\.img\.xz' >&2 || \
        echo "  (none found — directory may be empty or structure changed)" >&2
    exit 1
fi

echo "${DIR_URL}${MATCH}"
