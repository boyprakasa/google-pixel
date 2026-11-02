#!/usr/bin/env bash
#
# build_and_root.sh — Build Lunaris AOSP ROM then auto-patch init_boot.img
# with KernelSU-Next (ksud boot-patch), so the flashable output is already
# rooted. No manual re-patching needed after every build.
#
# Background (from the shiba/husky bring-up session):
#   - Kernel is a prebuilt GKI (device/google/shusky-kernels), not compiled
#     from source here, so KernelSU cannot be built directly into the
#     kernel image. The practical alternative is to patch init_boot.img as
#     a post-build step using ksud's LKM (loadable kernel module) mode.
#   - Pixel 8 / 8 Pro (Android 13+ GKI 2.0) use a separate init_boot
#     partition for the ramdisk — LKM mode patches init_boot, not boot.
#   - KMI for this build is android16-6.1 (kernel manifest branch was
#     android-gs-shusky-6.1-android16). Override with --kmi if this is
#     wrong for your actual kernel build.
#
# Usage:
#   ./build_and_root.sh <device> [variant]
#   ./build_and_root.sh shiba user         # release-style, minimal logging, no root shell by default
#   ./build_and_root.sh shiba userdebug    # default — debuggable, root via su, adb root works
#   ./build_and_root.sh husky eng          # development build, most permissive, slower/larger
#
# variant defaults to "userdebug" if omitted.
#
# One-time setup before running this script:
#   1. Place a `ksud` binary (Linux x86_64) at ./tools/ksud, or set KSUD_BIN
#      to its path. Download from:
#      https://github.com/KernelSU-Next/KernelSU-Next/releases
#   2. Place a `magiskboot` binary (Linux x86_64) at ./tools/magiskboot, or
#      set MAGISKBOOT_BIN to its path. Can be extracted from a recent
#      Magisk APK's assets (arm64-v8a or x86_64 build, lib/x86_64/libmagiskboot.so
#      renamed), or built from https://github.com/topjohnwu/Magisk.
#
set -Eeuo pipefail

DEVICE="${1:-}"
VARIANT="${2:-userdebug}"
KMI="${KSU_KMI:-android16-6.1}"
KSUD_BIN="${KSUD_BIN:-./tools/ksud}"
MAGISKBOOT_BIN="${MAGISKBOOT_BIN:-./tools/magiskboot}"

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'

log(){ echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
die(){ echo -e "${C_RED}[ERROR]${C_RESET} $*"; exit 1; }

[[ -n "$DEVICE" ]] || die "Usage: $0 <device> [variant]   e.g. $0 shiba userdebug"
case "$VARIANT" in
    user|userdebug|eng) ;;
    *) die "Invalid variant: '$VARIANT' — must be one of: user, userdebug, eng" ;;
esac
[[ -f "build/envsetup.sh" ]] || die "Run this from the root of your Lunaris source tree (build/envsetup.sh not found)."
[[ -x "$KSUD_BIN" ]] || die "ksud binary not found/executable at: $KSUD_BIN (see header comment for download instructions)"
[[ -x "$MAGISKBOOT_BIN" ]] || die "magiskboot binary not found/executable at: $MAGISKBOOT_BIN (see header comment for download instructions)"

PRODUCT_OUT="out/target/product/${DEVICE}"

log "Building lunaris_${DEVICE}-${VARIANT} ..."
log "(SKIP_KERNEL_BUILD is forced true — kernel is prebuilt, not compiled from source here)"
if [[ "$VARIANT" == "user" ]]; then
    warn "variant=user: adb root / su shell from AOSP itself is disabled by default (ro.secure=1, ro.debuggable=0)."
    warn "KernelSU-Next root still works regardless (it's a separate mechanism via its kernel module + manager app),"
    warn "but debugging via 'adb root' / 'adb shell su' won't — use the KernelSU Manager app's root prompt instead."
fi

# shellcheck disable=SC1091
source build/envsetup.sh

export SKIP_KERNEL_BUILD=true

lunch "lunaris_${DEVICE}-${VARIANT}"
m bacon -j"$(nproc --all)"

ok "Build finished."

INIT_BOOT_IMG="${PRODUCT_OUT}/init_boot.img"
BOOT_IMG="${PRODUCT_OUT}/boot.img"

if [[ -f "$INIT_BOOT_IMG" ]]; then
    TARGET_IMG="$INIT_BOOT_IMG"
    log "Found init_boot.img — this device uses GKI 2.0 (separate init_boot partition), patching that."
elif [[ -f "$BOOT_IMG" ]]; then
    TARGET_IMG="$BOOT_IMG"
    warn "No init_boot.img found — falling back to boot.img. Verify this is correct for your device/Android version."
else
    die "Neither init_boot.img nor boot.img found in ${PRODUCT_OUT}/ — build may have failed or produced a different layout."
fi

PATCH_DIR="${PRODUCT_OUT}/ksu_patch_work"
mkdir -p "$PATCH_DIR"

log "Patching $(basename "$TARGET_IMG") with KernelSU-Next (KMI: $KMI) ..."
"$KSUD_BIN" boot-patch \
    -b "$TARGET_IMG" \
    --kmi "$KMI" \
    --magiskboot "$MAGISKBOOT_BIN" \
    -o "$PATCH_DIR"

PATCHED_IMG="$(find "$PATCH_DIR" -maxdepth 1 -iname "*patched*.img" -o -iname "*_ksu.img" 2>/dev/null | head -1)"
# Some ksud versions name the output simply after the input file; fall back
# to "the newest .img file in the work dir" if the pattern above misses it.
if [[ -z "$PATCHED_IMG" ]]; then
    PATCHED_IMG="$(find "$PATCH_DIR" -maxdepth 1 -iname "*.img" -newer "$TARGET_IMG" 2>/dev/null | head -1)"
fi

[[ -n "$PATCHED_IMG" && -f "$PATCHED_IMG" ]] || die "ksud ran but no patched output image was found in $PATCH_DIR — inspect that folder manually."

ok "Patched image: $PATCHED_IMG"

BACKUP_IMG="${TARGET_IMG}.unpatched.bak"
if [[ ! -f "$BACKUP_IMG" ]]; then
    cp "$TARGET_IMG" "$BACKUP_IMG"
    log "Backed up original stock image to: $BACKUP_IMG"
fi

cp "$PATCHED_IMG" "$TARGET_IMG"
ok "Replaced $(basename "$TARGET_IMG") in ${PRODUCT_OUT}/ with the KernelSU-Next patched version."

echo
echo -e "${C_BOLD}${C_GREEN}========== DONE ==========${C_RESET}"
echo "Device:     $DEVICE"
echo "Patched:    $TARGET_IMG"
echo "Stock backup: $BACKUP_IMG"
echo
echo "Flash as usual (fastboot flashall / per-partition fastboot flash)."
echo "This init_boot/boot image is now pre-rooted — no separate manual"
echo "patch step needed after flashing. Re-run this script after every"
echo "rebuild to produce a freshly patched image."
echo -e "${C_BOLD}${C_GREEN}===========================${C_RESET}"
