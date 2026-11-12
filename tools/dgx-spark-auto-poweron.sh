#!/usr/bin/env bash
#
# dgx-spark-auto-poweron.sh
#
# Enables "Restore on AC Power Loss = Power On" on a DGX Spark (or any
# system with AMI BIOS using the standard Setup var).
#
# On a headless DGX Spark, this turns the box into a node that auto-powers-on
# after power loss (or after `poweroff`/`shutdown` from the OS).
#
# USE AT YOUR OWN RISK. This script writes to the BIOS UEFI Setup variable,
# which is non-volatile storage on the mainboard. A failed or partial write
# could in theory cause boot issues. The script:
#   1. Backs up the current Setup var to a safe location
#   2. Modifies byte 3 (question ID 1d->1c) and byte 4 (value 00->01)
#   3. Writes via the kernel EFI variable API (efivar -w), which is the
#      only reliable write path on Linux
#   4. Verifies the change
#
# Verified to work on:
#   - DGX Spark GB10 BIOS GX10DGX.0103.2026.0129.1152
#   - DGX Spark GB10 BIOS 5.36_0ACUM018 (older firmware)
#   - Same setting also exists in newer BIOS revisions (e.g. GX10DGX.0104)
#
# If your BIOS is different, run with --check first to see what it would do.
#
# Requirements (auto-installed if missing):
#   - Linux with EFI firmware
#   - efivar tool (apt install efivar)
#   - sudo / root
#   - kernel EFI variable support (CONFIG_EFI_VARS)
#
# Usage:
#   ./dgx-spark-auto-poweron.sh                  # apply (interactive)
#   ./dgx-spark-auto-poweron.sh --check          # show current state, no change
#   ./dgx-spark-auto-poweron.sh --status         # show current state + backups
#   ./dgx-spark-auto-poweron.sh --revert         # restore from backup
#   ./dgx-spark-auto-poweron.sh --dry-run        # show what would change, no write
#   ./dgx-spark-auto-poweron.sh --help           # show help

set -euo pipefail

PROG="$(basename "$0")"
SETUP_VAR="/sys/firmware/efi/efivars/Setup-ec87d643-eba4-4bb5-a1e5-3f3e36b20da9"
SETUP_NAME="ec87d643-eba4-4bb5-a1e5-3f3e36b20da9-Setup"
BAK_DIR="/var/lib/dgx-spark-auto-poweron"
LOG_TAG="[$PROG]"
DRY_RUN=0
YES=0

# Colors (only when stdout is a TTY)
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'
    C_YEL=$'\033[1;33m'
    C_GRN=$'\033[0;32m'
    C_CYN=$'\033[0;36m'
    C_BLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

log()  { echo "$LOG_TAG $*" >&2; }
warn() { echo "$LOG_TAG ${C_YEL}WARN${C_OFF}: $*" >&2; }
err()  { echo "$LOG_TAG ${C_RED}ERROR${C_OFF}: $*" >&2; }
ok()   { echo "$LOG_TAG ${C_GRN}OK${C_OFF}: $*" >&2; }
info() { echo "$LOG_TAG ${C_CYN}INFO${C_OFF}: $*" >&2; }
title() { echo "${C_BLD}== $* ==${C_OFF}" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "must be run as root (try: sudo $0)"
        exit 1
    fi
}

# Auto-fix: install missing tools
install_efivar() {
    if command -v efivar >/dev/null 2>&1; then
        return 0
    fi
    warn "efivar tool not found - attempting to install"
    if command -v apt-get >/dev/null 2>&1; then
        if apt-get install -y efivar 2>&1 | tail -3; then
            ok "efivar installed"
            return 0
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if dnf install -y efivar 2>&1 | tail -3; then
            ok "efivar installed"
            return 0
        fi
    elif command -v yum >/dev/null 2>&1; then
        if yum install -y efivar 2>&1 | tail -3; then
            ok "efivar installed"
            return 0
        fi
    fi
    err "could not auto-install efivar"
    err "Please install it manually:"
    err "  Debian/Ubuntu: sudo apt install efivar"
    err "  RHEL/Fedora:   sudo dnf install efivar"
    return 1
}

check_prereqs() {
    local missing=0

    # Check EFI firmware (kernel EFI vars must exist)
    if [[ ! -d "/sys/firmware/efi/efivars" ]]; then
        err "EFI vars not exposed. Are you booted in EFI mode?"
        err "Check: ls /sys/firmware/efi/efivars 2>/dev/null | head -3"
        err "This script requires UEFI firmware."
        missing=1
    fi

    # Check Setup var exists
    if [[ ! -f "$SETUP_VAR" ]]; then
        err "EFI Setup variable not found at $SETUP_VAR"
        err "This is normal for non-DGX-Spark or non-AMI-BIOS systems."
        missing=1
    fi

    # Auto-install efivar if missing
    if ! install_efivar; then
        missing=1
    fi

    # Check python3
    if ! command -v python3 >/dev/null 2>&1; then
        err "python3 not found. This is unusual for modern Linux."
        missing=1
    fi

    if [[ $missing -ne 0 ]]; then
        exit 1
    fi
}

# Safety: identify platform & warn if not DGX Spark
safety_check() {
    local product
    local bios_vendor
    local cpu_model
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
    bios_vendor="$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo unknown)"
    # CPU model - use lscpu or fall back to /proc/cpuinfo
    if command -v lscpu >/dev/null 2>&1; then
        cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    fi
    if [[ -z "${cpu_model:-}" ]]; then
        cpu_model="$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | head -1 | sed 's/^model name[ \t]*: *//' || echo unknown)"
    fi
    cpu_model="${cpu_model:-unknown}"

    info "Platform detected:"
    info "  Product: $product"
    info "  BIOS: $bios_vendor"
    info "  CPU: $cpu_model"

    # Warn if not DGX Spark
    case "$product" in
        *NVIDIA_DGX_Spark*|*GX10*)
            info "  -> Recognized as DGX Spark (or compatible)"
            ;;
        *)
            warn "Product '$product' is not recognized as DGX Spark."
            warn "This script was developed for DGX Spark GB10."
            warn "It MAY work on other systems with AMI BIOS using the standard"
            warn "Setup var, but no guarantees. The BIOS schema must match."
            warn ""
            if [[ -t 0 ]] && [[ "${YES:-0}" != "1" ]]; then
                read -p "Continue anyway? [y/N] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    info "Aborted."
                    exit 0
                fi
            else
                warn "Non-interactive mode without --yes. Aborting for safety."
                exit 1
            fi
            ;;
    esac
}

# read_setup: prints "STATE:OFF" or "STATE:ON" or "STATE:UNKNOWN:hexbytes"
read_setup_state() {
    python3 - "$SETUP_VAR" <<'PYEOF'
import sys
SETUP_VAR = sys.argv[1]
try:
    with open(SETUP_VAR, "rb") as f:
        raw = f.read()
    if len(raw) < 8:
        print("STATE:UNKNOWN:file-too-small")
        sys.exit(0)
    content = raw[4:]  # skip sysfs header
    qid, val = content[3], content[4]
    if qid == 0x1c and val == 0x01:
        print("STATE:ON")
    elif qid == 0x1d and val == 0x00:
        print("STATE:OFF")
    else:
        print(f"STATE:UNKNOWN:qid={qid:02x},val={val:02x}")
except FileNotFoundError:
    print("STATE:NOVAR")
except PermissionError:
    print("STATE:PERM")
PYEOF
}

# backup_setup: copies current Setup var content. Echoes backup path on stdout.
backup_setup() {
    mkdir -p "$BAK_DIR"
    chmod 700 "$BAK_DIR" 2>/dev/null || true
    local ts backup tmpfile
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="$BAK_DIR/Setup.$(hostname).${ts}.bak"
    tmpfile="$(mktemp)"

    python3 - "$SETUP_VAR" "$backup" "$tmpfile" <<'PYEOF' >/dev/null
import sys, hashlib, os
src, dst, info_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "rb") as f:
    raw = f.read()
content = raw[4:]  # skip sysfs header
with open(dst, "wb") as f:
    f.write(content)
h = hashlib.sha256(content).hexdigest()
size = len(content)
with open(info_file, "w") as f:
    f.write(f"{h} {size}")
os.chmod(dst, 0o600)
PYEOF

    local h size
    h=$(cut -d' ' -f1 "$tmpfile" 2>/dev/null || echo unknown)
    size=$(cut -d' ' -f2 "$tmpfile" 2>/dev/null || echo unknown)
    rm -f "$tmpfile"
    info "  size=$size sha256=${h:0:16}"

    echo "$backup"
}

# write_setup: writes modified content to EFI var via kernel API
write_setup() {
    local src="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY RUN] would write $src to EFI var"
        return 0
    fi
    # Attributes: Non-Volatile + Boot Service + Runtime Access = 7
    efivar -w -n "$SETUP_NAME" -A 7 -f "$src"
}

verify_setup() {
    local state
    state="$(read_setup_state)"
    case "$state" in
        STATE:ON)  ok "BIOS setting is POWER ON (auto-power-on enabled)"; return 0 ;;
        STATE:OFF) ok "BIOS setting is POWER OFF (auto-power-on disabled)"; return 0 ;;
        *)         err "Unexpected state: $state"; return 1 ;;
    esac
}

show_status() {
    local state
    state="$(read_setup_state)"
    title "EFI Setup var: $SETUP_VAR"
    title "Current state: $state"
    case "$state" in
        STATE:ON)  ok "Auto-power-on is ENABLED" ;;
        STATE:OFF) info "Auto-power-on is DISABLED" ;;
        STATE:NOVAR) warn "Setup var not found" ;;
        STATE:PERM) warn "Permission denied reading Setup var" ;;
        *)         warn "Unknown state (may indicate a different BIOS schema)" ;;
    esac

    echo ""
    info "Backups in $BAK_DIR/:"
    if [[ -d "$BAK_DIR" ]] && ls -1 "$BAK_DIR"/*.bak 2>/dev/null | head -5 | grep -q .; then
        ls -la "$BAK_DIR"/*.bak 2>/dev/null | head -10
    else
        echo "  (none)"
    fi
}

cmd_check() {
    require_root
    check_prereqs
    info "Showing current state (no changes)"
    show_status
}

cmd_status() {
    require_root
    check_prereqs
    show_status
}

cmd_apply() {
    require_root
    check_prereqs
    safety_check

    title "Applying auto-power-on setting"

    local current
    current="$(read_setup_state)"
    info "Current state: $current"

    case "$current" in
        STATE:ON)
            ok "Already in POWER ON state. Nothing to do."
            exit 0
            ;;
        STATE:NOVAR)
            err "Setup var not found. Cannot apply."
            exit 1
            ;;
        STATE:PERM)
            err "Permission denied reading Setup var."
            exit 1
            ;;
        STATE:UNKNOWN:*)
            warn "Current state is $current"
            warn "Expected byte 3=0x1d, byte 4=0x00 for OFF state."
            warn "Applying will set byte 3=0x1c, byte 4=0x01 regardless."
            warn ""
            if [[ -t 0 ]] && [[ "${YES:-0}" != "1" ]]; then
                read -p "Continue? [y/N] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    info "Aborted."
                    exit 0
                fi
            else
                warn "Non-interactive without --yes, aborting."
                exit 1
            fi
            ;;
    esac

    info "Backing up current state to $BAK_DIR/..."
    local backup
    backup="$(backup_setup)"
    ok "Backup saved: $backup"

    info "Building modified Setup var content"
    info "  byte 3: 0x1d -> 0x1c (After Power Loss question ID)"
    info "  byte 4: 0x00 -> 0x01 (value: off -> on)"

    local modified="$BAK_DIR/Setup.modified.$$"
    python3 - "$backup" "$modified" <<'PYEOF'
import sys, hashlib
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = bytearray(f.read())
data[3] = 0x1c
data[4] = 0x01
with open(dst, "wb") as f:
    f.write(data)
print(f"  -> {len(data)} bytes written to {dst}")
PYEOF

    info "Writing modified content via efivar (kernel EFI variable API)..."
    if write_setup "$modified"; then
        if [[ "$DRY_RUN" == "1" ]]; then
            ok "[DRY RUN] write simulated"
        else
            ok "Write succeeded"
        fi
        rm -f "$modified"
    else
        err "efivar write failed"
        err "To rollback, run: sudo $0 --revert"
        exit 1
    fi

    echo ""
    verify_setup

    if [[ "$DRY_RUN" == "1" ]]; then
        echo ""
        info "[DRY RUN] no changes made. Run without --dry-run to apply."
        exit 0
    fi

    echo ""
    info "REBOOT to make the change effective:"
    info "  sudo reboot"
    info ""
    info "After reboot, verify with: sudo $0 --status"
    info ""
    info "To test: shutdown the system with 'sudo poweroff' or 'sudo shutdown now'"
    info "The system should automatically power back on within a few seconds."
    info "(the BIOS treats AC loss and OS shutdown identically for this setting)"
}

cmd_revert() {
    require_root
    check_prereqs

    if [[ ! -d "$BAK_DIR" ]]; then
        err "Backup directory $BAK_DIR does not exist"
        err "Cannot auto-revert. Manually flash BIOS or contact vendor support."
        exit 1
    fi

    local latest
    latest="$(ls -1t "$BAK_DIR"/*.bak 2>/dev/null | head -1 || true)"
    if [[ -z "$latest" ]]; then
        err "No backup found in $BAK_DIR"
        exit 1
    fi

    info "Reverting to backup: $latest"

    # Confirmation (skip if --yes or --dry-run)
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY RUN] would revert to $latest"
        exit 0
    fi

    if [[ "${YES:-0}" != "1" ]]; then
        if [[ ! -t 0 ]]; then
            err "Refusing to revert non-interactively. Use --yes to skip confirmation."
            exit 1
        fi
        read -p "Revert to this backup? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Aborted."
            exit 0
        fi
    fi

    if write_setup "$latest"; then
        ok "Reverted to backup"
    else
        err "efivar write failed during revert"
        exit 1
    fi

    verify_setup
}

usage() {
    cat <<EOF
$PROG - Enable auto-power-on on DGX Spark (headless)

USAGE:
    $0 [OPTIONS] [COMMAND]

COMMANDS:
    (no args)        Apply auto-power-on (interactive)
    --check          Show current state (no changes)
    --status         Show state + backups
    --revert         Restore from most recent backup
    --dry-run        Show what would change, no write
    --help           Show this help

OPTIONS:
    --yes            Skip confirmation prompts
    --dry-run        Don't actually write (use with --revert or apply)

BACKUPS:
    Saved to $BAK_DIR/

REQUIREMENTS:
    - Linux with EFI firmware (auto-checks)
    - efivar tool (auto-installs if missing)
    - python3 (auto-checks)
    - sudo / root (required)

USE AT YOUR OWN RISK.

EXAMPLES:
    sudo $0                  # apply (interactive)
    sudo $0 --check          # just show current state
    sudo $0 --dry-run        # show what would change
    sudo $0 --revert --yes   # revert non-interactively
EOF
}

main() {
    # Parse flags
    local cmd=""
    YES=0
    DRY_RUN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) YES=1; shift ;;
            --dry-run|--dry_run) DRY_RUN=1; shift ;;
            --check|--status|--revert|--help|-h)
                cmd="$1"; shift ;;
            "") break ;;
            *) usage; exit 1 ;;
        esac
    done

    case "$cmd" in
        ""             ) cmd_apply ;;
        --check        ) cmd_check ;;
        --status       ) cmd_status ;;
        --revert       ) cmd_revert ;;
        --help|-h      ) usage; exit 0 ;;
        *              ) usage; exit 1 ;;
    esac
}

main "$@"
