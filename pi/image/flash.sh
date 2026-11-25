#!/usr/bin/env bash
#
# Flash Raspberry Pi OS Lite (32-bit, armhf) for the birdmic Pi 2 and seed
# cloud-init with hostname, user, SSH key, timezone, locale and Ethernet DHCP.
#
# Dry-run by default. Writing needs both --write and --device, plus typing the
# device path again at the prompt.
#
#   ./flash.sh                                  # download, verify, render config
#   ./flash.sh --device /dev/disk6              # same, plus device safety checks
#   ./flash.sh --write --device /dev/disk6      # really write (asks to confirm)
#
# macOS: the write is done by the Raspberry Pi Imager CLI (it verifies the
# uncompressed image hash and writes the cloud-init files to the boot
# partition). Linux: Imager CLI if installed, otherwise xz | dd plus copying the
# cloud-init files by hand.

set -euo pipefail

# Pinned image. Source: https://downloads.raspberrypi.com/os_list_imagingutility_v4.json
# ("Raspberry Pi OS Lite (32-bit)", init_format cloudinit-rpi) and the .sha256
# file published next to the image.
IMAGE_RELEASE="2026-10-06"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2026-10-06/2026-10-06-raspios-trixie-armhf-lite.img.xz"
IMAGE_XZ_SHA256="2c302771f34c67a0b7ae7aa2e0dcdd3eac660504be59193c011ba79d412e1632"
IMAGE_SHA256="acf39427d33c997fc2bbc237cc48a30f3b00c9cd60b831d67fedc9e3205fa816"

# First-boot settings (all overridable with flags).
PI_HOSTNAME="birdmic"
PI_USER="pi"
SSH_PUBKEY_FILE="${HOME}/.ssh/id_ed25519.pub"
PI_TIMEZONE="Europe/Amsterdam"
PI_LOCALE="en_GB.UTF-8"

MAX_DEVICE_BYTES=$((256 * 1000 * 1000 * 1000))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/.cache"
RPI_IMAGER="${RPI_IMAGER:-}"

DEVICE=""
WRITE=0
DOWNLOAD=1
OS="$(uname -s)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --device PATH      target whole disk (macOS /dev/diskN, Linux /dev/sdX or /dev/mmcblkN)
  --write            really write the card (without it this is a dry run)
  --hostname NAME    hostname (default: ${PI_HOSTNAME})
  --user NAME        login user (default: ${PI_USER})
  --ssh-key FILE     public key for that user (default: ${SSH_PUBKEY_FILE})
  --timezone TZ      timezone (default: ${PI_TIMEZONE})
  --locale LOCALE    locale (default: ${PI_LOCALE})
  --cache-dir DIR    download cache (default: ${CACHE_DIR})
  --no-download      dry run without fetching the image
  -h, --help         this help

Image: ${IMAGE_URL}
EOF
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device) DEVICE="${2:-}"; shift 2 ;;
            --write) WRITE=1; shift ;;
            --hostname) PI_HOSTNAME="${2:-}"; shift 2 ;;
            --user) PI_USER="${2:-}"; shift 2 ;;
            --ssh-key) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
            --timezone) PI_TIMEZONE="${2:-}"; shift 2 ;;
            --locale) PI_LOCALE="${2:-}"; shift 2 ;;
            --cache-dir) CACHE_DIR="${2:-}"; shift 2 ;;
            --no-download) DOWNLOAD=0; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
    done

    if [[ $WRITE -eq 1 ]]; then
        [[ -n "$DEVICE" ]] || die "--write needs --device"
        [[ $DOWNLOAD -eq 1 ]] || die "--write cannot be combined with --no-download"
    fi
    [[ "$PI_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid hostname: $PI_HOSTNAME"
    [[ "$PI_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $PI_USER"
    [[ "$PI_TIMEZONE" =~ ^[A-Za-z0-9_/+-]+$ ]] || die "invalid timezone: $PI_TIMEZONE"
    [[ "$PI_LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "invalid locale: $PI_LOCALE"
}

# --- image ------------------------------------------------------------------

IMAGE_FILE=""

fetch_image() {
    IMAGE_FILE="${CACHE_DIR}/$(basename "$IMAGE_URL")"
    mkdir -p "$CACHE_DIR"

    if [[ -f "$IMAGE_FILE" ]]; then
        log "Cached image: $IMAGE_FILE"
    elif [[ $DOWNLOAD -eq 0 ]]; then
        log "Skipping download (--no-download); image not cached"
        IMAGE_FILE=""
        return
    else
        log "Downloading $IMAGE_URL"
        curl -fL# --retry 3 -C - -o "${IMAGE_FILE}.part" "$IMAGE_URL"
        mv "${IMAGE_FILE}.part" "$IMAGE_FILE"
    fi

    log "Verifying SHA256 of the compressed image"
    local actual
    actual="$(sha256_of "$IMAGE_FILE")"
    if [[ "$actual" != "$IMAGE_XZ_SHA256" ]]; then
        rm -f "$IMAGE_FILE"
        die "SHA256 mismatch (expected $IMAGE_XZ_SHA256, got $actual); cached file removed"
    fi
    log "SHA256 OK: $actual"
}

# --- cloud-init -------------------------------------------------------------

USERDATA_FILE=""
NETCFG_FILE=""

# Mirrors what Raspberry Pi Imager 2.x generates for cloudinit-rpi images
# (src/customization_generator.cpp), minus avahi and Wi-Fi. Imager prepends
# the "#cloud-config" header itself, so the body file has none.
render_cloud_init() {
    [[ -r "$SSH_PUBKEY_FILE" ]] || die "SSH public key not readable: $SSH_PUBKEY_FILE"
    local key
    key="$(grep -E '^(ssh-|ecdsa-|sk-)' "$SSH_PUBKEY_FILE" | head -n 1 | sed -E 's/[[:space:]]+$//')"
    [[ -n "$key" ]] || die "no public key found in $SSH_PUBKEY_FILE"
    [[ "$key" =~ ^[A-Za-z0-9@._+/=:\ -]+$ ]] || die "unexpected characters in $SSH_PUBKEY_FILE"

    local dir="${CACHE_DIR}/cloud-init"
    mkdir -p "$dir"
    USERDATA_FILE="${dir}/user-data.body"
    NETCFG_FILE="${dir}/network-config"

    cat >"$USERDATA_FILE" <<EOF
manage_resolv_conf: false

hostname: "${PI_HOSTNAME}"
manage_etc_hosts: true
timezone: "${PI_TIMEZONE}"
locale: "${PI_LOCALE}"

user:
  name: "${PI_USER}"
  shell: /bin/bash
  lock_passwd: true
  ssh_authorized_keys:
    - "${key}"
  sudo: ALL=(ALL) NOPASSWD:ALL

ssh_pwauth: false

runcmd:
  - [ systemctl, enable, --now, ssh ]
EOF

    cat >"$NETCFG_FILE" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: true
      optional: true
EOF

    log "Rendered cloud-init files in $dir"
    printf -- '--- user-data (Imager adds the #cloud-config header) ---\n'
    cat "$USERDATA_FILE"
    printf -- '--- network-config ---\n'
    cat "$NETCFG_FILE"
    printf -- '---\n'
}

# --- device checks: macOS ---------------------------------------------------

plist_get() {
    # $1 = plist xml, $2 = key path; prints raw value, fails if missing
    plutil -extract "$2" raw -o - - <<<"$1" 2>/dev/null
}

# Whole disks (physical or synthesized) that back a disk or volume.
mac_backing_disks() {
    local plist parent store i=0
    plist="$(diskutil info -plist "$1" 2>/dev/null)" || return 0
    parent="$(plist_get "$plist" ParentWholeDisk)" || return 0
    printf '%s\n' "$parent"
    while store="$(plist_get "$plist" "APFSPhysicalStores.${i}.APFSPhysicalStore")"; do
        mac_backing_disks "$store"
        i=$((i + 1))
    done
}

# Whole disks that host /, /System/Volumes/* or other non /Volumes mounts.
mac_system_disks() {
    local dev mnt
    while read -r dev mnt; do
        [[ "$dev" == /dev/disk* ]] || continue
        [[ "$mnt" == /Volumes/* ]] || mac_backing_disks "$dev"
    done < <(mount | sed -E 's#^([^ ]+) on (.+) \([^)]*\)$#\1 \2#')
    mac_backing_disks /
}

check_device_macos() {
    local dev="$DEVICE"
    dev="${dev/#\/dev\/rdisk//dev/disk}"
    [[ "$dev" =~ ^/dev/disk[0-9]+$ ]] || die "device must be a whole disk like /dev/disk6 (got $DEVICE)"
    DEVICE="$dev"
    local id="${dev#/dev/}"

    log "diskutil list"
    diskutil list
    printf '\n'

    local plist
    plist="$(diskutil info -plist "$dev" 2>/dev/null)" || die "diskutil does not know $dev"

    local whole virt proto size osint internal removable name
    whole="$(plist_get "$plist" WholeDisk || echo false)"
    virt="$(plist_get "$plist" VirtualOrPhysical || echo unknown)"
    proto="$(plist_get "$plist" BusProtocol || echo unknown)"
    size="$(plist_get "$plist" TotalSize || echo 0)"
    osint="$(plist_get "$plist" OSInternalMedia || echo false)"
    internal="$(plist_get "$plist" Internal || echo unknown)"
    removable="$(plist_get "$plist" RemovableMediaOrExternalDevice || echo unknown)"
    name="$(plist_get "$plist" MediaName || echo unknown)"

    log "Target $dev: ${name}, $((size / 1000000)) MB, protocol ${proto}, ${virt}, internal=${internal}, removable/external=${removable}"

    [[ "$whole" == "true" ]] || die "$dev is not a whole disk"
    [[ "$id" != "disk0" ]] || die "refusing disk0 (system disk)"
    [[ "$osint" != "true" ]] || die "refusing $dev: it is the OS internal media"
    [[ "$virt" == "Physical" ]] || die "refusing $dev: not a physical disk (${virt}, synthesized or disk image)"
    [[ "$proto" != "Disk Image" ]] || die "refusing $dev: it is a disk image"
    [[ "$size" -gt 0 ]] || die "refusing $dev: no media or unknown size"
    [[ "$size" -le "$MAX_DEVICE_BYTES" ]] || die "refusing $dev: larger than 256 GB ($size bytes)"

    local sys
    while read -r sys; do
        [[ -n "$sys" ]] || continue
        [[ "$sys" != "$id" ]] || die "refusing $dev: it backs the boot volume or a mounted system volume"
    done < <(mac_system_disks | sort -u)

    log "Safety checks passed for $dev"
}

# --- device checks: Linux ---------------------------------------------------

check_device_linux() {
    local dev="$DEVICE"
    [[ -b "$dev" ]] || die "$dev is not a block device"

    log "lsblk"
    lsblk -o NAME,SIZE,TYPE,RM,TRAN,MODEL,MOUNTPOINTS
    printf '\n'

    local type size tran
    type="$(lsblk -dno TYPE "$dev")"
    size="$(lsblk -bdno SIZE "$dev")"
    tran="$(lsblk -dno TRAN "$dev" || true)"
    log "Target $dev: type ${type}, $((size / 1000000)) MB, transport ${tran:-unknown}"

    [[ "$type" == "disk" ]] || die "refusing $dev: type is $type, not a whole disk"
    [[ "$size" -gt 0 ]] || die "refusing $dev: no media"
    [[ "$size" -le "$MAX_DEVICE_BYTES" ]] || die "refusing $dev: larger than 256 GB ($size bytes)"

    local mnt src pk
    for mnt in / /boot /boot/efi /usr /var /home; do
        src="$(findmnt -no SOURCE "$mnt" 2>/dev/null || true)"
        [[ -n "$src" && -b "$src" ]] || continue
        pk="$(lsblk -no PKNAME "$src" 2>/dev/null | tail -n 1)"
        if [[ "/dev/${pk}" == "$dev" || "$src" == "$dev" ]]; then
            die "refusing $dev: it hosts $mnt"
        fi
    done
    if lsblk -no MOUNTPOINTS "$dev" | grep -q '\[SWAP\]'; then
        die "refusing $dev: it holds active swap"
    fi

    log "Safety checks passed for $dev"
}

# --- write ------------------------------------------------------------------

find_imager() {
    if [[ -n "$RPI_IMAGER" ]]; then
        [[ -x "$RPI_IMAGER" ]] || die "RPI_IMAGER=$RPI_IMAGER is not executable"
        return
    fi
    local candidate
    for candidate in "/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager" \
        "$(command -v rpi-imager 2>/dev/null || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            RPI_IMAGER="$candidate"
            return
        fi
    done
}

imager_cmd() {
    # Never pass --enable-writing-system-drives: Imager's own removable-drive
    # check stays on as a second safety net.
    IMAGER_ARGS=(--cli --sha256 "$IMAGE_SHA256"
        --cloudinit-userdata "$USERDATA_FILE"
        --cloudinit-networkconfig "$NETCFG_FILE"
        "$IMAGE_FILE" "$DEVICE")
}

confirm_device() {
    [[ -t 0 ]] || die "confirmation needs an interactive terminal"
    printf '\nThis ERASES everything on %s.\n' "$DEVICE"
    local answer
    read -r -p "Type the device path again to confirm: " answer
    [[ "$answer" == "$DEVICE" ]] || die "confirmation did not match, nothing written"
}

write_with_imager() {
    imager_cmd
    log "Running Raspberry Pi Imager CLI"
    if [[ "$OS" == "Darwin" ]]; then
        # Imager gets raw disk access through authopen (password dialog).
        "$RPI_IMAGER" "${IMAGER_ARGS[@]}"
    else
        sudo "$RPI_IMAGER" "${IMAGER_ARGS[@]}"
    fi
}

write_with_dd_linux() {
    local bootpart mnt id
    log "Writing with xz | dd to $DEVICE"
    xz -dc "$IMAGE_FILE" | sudo dd of="$DEVICE" bs=4M conv=fsync status=progress
    sync
    sudo partprobe "$DEVICE" 2>/dev/null || true
    sleep 2

    if [[ "$DEVICE" =~ [0-9]$ ]]; then bootpart="${DEVICE}p1"; else bootpart="${DEVICE}1"; fi
    mnt="$(mktemp -d)"
    sudo mount "$bootpart" "$mnt"

    # Same layout Imager writes: NoCloud seed on the FAT partition plus the
    # datasource and instance id on the kernel command line.
    id="birdmic-flash-$(date +%s)"
    printf 'instance-id: %s\n' "$id" | sudo tee "$mnt/meta-data" >/dev/null
    { printf '#cloud-config\n'; cat "$USERDATA_FILE"; } | sudo tee "$mnt/user-data" >/dev/null
    sudo cp "$NETCFG_FILE" "$mnt/network-config"
    sudo sed -i "1 s|\$| ds=nocloud;i=${id}|" "$mnt/cmdline.txt"

    sync
    sudo umount "$mnt"
    rmdir "$mnt"
}

main() {
    parse_args "$@"

    if [[ $WRITE -eq 1 ]]; then
        log "WRITE MODE: $DEVICE will be erased after confirmation"
    else
        log "DRY RUN: nothing will be written (use --write --device PATH to flash)"
    fi
    log "Image ${IMAGE_RELEASE}: $(basename "$IMAGE_URL")"

    render_cloud_init
    fetch_image

    if [[ -n "$DEVICE" ]]; then
        case "$OS" in
            Darwin) check_device_macos ;;
            Linux) check_device_linux ;;
            *) die "unsupported OS: $OS" ;;
        esac
    fi

    find_imager
    if [[ "$OS" == "Darwin" && -z "$RPI_IMAGER" ]]; then
        die "Raspberry Pi Imager not found (install it, or set RPI_IMAGER=/path/to/rpi-imager)"
    fi

    if [[ $WRITE -eq 0 ]]; then
        if [[ -z "$DEVICE" ]]; then
            log "No --device given; device checks skipped"
            return
        fi
        local img="${IMAGE_FILE:-<image not downloaded>}"
        log "Would ask to retype '$DEVICE', then run:"
        if [[ "$OS" == "Darwin" ]]; then
            printf '    diskutil unmountDisk %s\n' "$DEVICE"
        fi
        if [[ -n "$RPI_IMAGER" ]]; then
            IMAGE_FILE="$img"
            imager_cmd
            printf '   '
            printf ' %q' "$RPI_IMAGER" "${IMAGER_ARGS[@]}"
            printf '\n'
        else
            printf '    xz -dc %q | sudo dd of=%q bs=4M conv=fsync\n' "$img" "$DEVICE"
            printf '    then copy user-data, network-config, meta-data to the boot partition\n'
        fi
        log "Dry run finished, nothing written"
        return
    fi

    confirm_device

    if [[ "$OS" == "Darwin" ]]; then
        diskutil unmountDisk "$DEVICE"
        write_with_imager
        # Imager ejects on success; make sure it is gone either way.
        diskutil eject "$DEVICE" >/dev/null 2>&1 || true
    elif [[ -n "$RPI_IMAGER" ]]; then
        sudo umount "${DEVICE}"?* 2>/dev/null || true
        write_with_imager
    else
        sudo umount "${DEVICE}"?* 2>/dev/null || true
        write_with_dd_linux
        sudo eject "$DEVICE" 2>/dev/null || true
    fi

    log "Done. Insert the card in the Pi, power it via PoE and wait about 3 minutes for first boot."
}

main "$@"
