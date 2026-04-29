#!/bin/bash
# Runs inside the NFS-rooted reprovision environment (triggered by systemd).
# Reads parameters from the kernel cmdline, downloads the Armbian image,
# flashes it to the target storage, reverts the RouterOS DHCP state, and reboots.

set -euo pipefail
exec > >(tee /var/log/reprovision.log) 2>&1

log() { echo "[reprovision] $*"; }

# ── Parse kernel cmdline ────────────────────────────────────────────────────

cmdline_param() {
    grep -oP "(?<=\b${1}=)\S+" /proc/cmdline 2>/dev/null || true
}

BOARD_MODEL=$(cmdline_param board_model)
BOARD_MAC=$(cmdline_param board_mac)
BOARD_STORAGE=$(cmdline_param board_storage)   # nvme | emmc
ROS_HOST=$(cmdline_param ros_host)
ROS_USER=$(cmdline_param ros_user)
IMAGE_SERVER=$(cmdline_param image_server)

# ── Credentials (stored on NFS server, not in cmdline) ──────────────────────

CONF_FILE="/etc/reprovision.conf"
if [[ -f "${CONF_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
fi
ROS_PASS="${ROUTEROS_PASS:-}"

# ── Determine target block device ───────────────────────────────────────────

detect_target() {
    if [[ "${BOARD_STORAGE}" == "nvme" ]] && [[ -b /dev/nvme0n1 ]]; then
        echo "/dev/nvme0n1"
    elif [[ -b /dev/nvme0n1 ]]; then
        log "Primary storage is nvme but no NVMe found; falling back to eMMC"
        echo "/dev/mmcblk0"
    elif [[ -b /dev/mmcblk0 ]]; then
        echo "/dev/mmcblk0"
    else
        log "ERROR: No usable block device found"
        exit 1
    fi
}

TARGET_DEV=$(detect_target)

# ── Download image ───────────────────────────────────────────────────────────

IMAGE_URL="${IMAGE_SERVER}/${BOARD_MODEL}.img.xz"
IMAGE_FILE="/tmp/armbian.img.xz"

log "=== Armbian Reprovision ==="
log "Board:  ${BOARD_MODEL}"
log "MAC:    ${BOARD_MAC}"
log "Target: ${TARGET_DEV}"
log "Image:  ${IMAGE_URL}"
log ""
log "Downloading image…"

wget --progress=dot:giga -O "${IMAGE_FILE}" "${IMAGE_URL}"

# ── Flash image ──────────────────────────────────────────────────────────────

log "Flashing ${TARGET_DEV}…"

# Unmount any partitions on the target device before writing
for part in $(lsblk -ln -o NAME "${TARGET_DEV}" | tail -n +2); do
    umount "/dev/${part}" 2>/dev/null || true
done

xz --decompress --stdout "${IMAGE_FILE}" \
    | dd of="${TARGET_DEV}" bs=4M conv=fsync status=progress

sync
log "Flash complete."

# ── Restore U-Boot boot order (non-SPI boards only) ─────────────────────────

if command -v fw_setenv &>/dev/null && [[ -f /etc/fw_env.config ]]; then
    log "Restoring disk-first boot order via fw_setenv…"
    fw_setenv boot_targets "mmc0 nvme0 mmc1 pxe dhcp" || \
        log "WARNING: fw_setenv failed — boot order unchanged"
fi

# ── Notify RouterOS to disable PXE for this board ───────────────────────────

disable_pxe_on_routeros() {
    if [[ -z "${ROS_HOST}" ]] || [[ -z "${ROS_USER}" ]] || [[ -z "${ROS_PASS}" ]]; then
        log "WARNING: RouterOS credentials not set; skipping DHCP revert"
        return
    fi

    log "Disabling PXE on RouterOS for MAC ${BOARD_MAC}…"

    local lease_id
    lease_id=$(curl -sk \
        -u "${ROS_USER}:${ROS_PASS}" \
        "https://${ROS_HOST}/rest/ip/dhcp-server/lease" \
        --get --data-urlencode "mac-address=${BOARD_MAC}" \
        | python3 -c "
import sys, json
leases = json.load(sys.stdin)
print(leases[0]['.id']) if leases else print('')
" 2>/dev/null || true)

    if [[ -z "${lease_id}" ]]; then
        log "WARNING: No DHCP lease found for ${BOARD_MAC} — skipping RouterOS update"
        return
    fi

    curl -sk -X PATCH \
        -u "${ROS_USER}:${ROS_PASS}" \
        -H "Content-Type: application/json" \
        -d '{"dhcp-option": ""}' \
        "https://${ROS_HOST}/rest/ip/dhcp-server/lease/${lease_id}" \
        > /dev/null

    log "RouterOS DHCP option cleared for ${BOARD_MAC}."
}

disable_pxe_on_routeros

# ── Reboot ───────────────────────────────────────────────────────────────────

log "Reprovision complete. Rebooting in 5 s…"
sleep 5
reboot
