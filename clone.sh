#!/usr/bin/env bash
# Android Source Cloner
#
# Original author : Bias8145 (https://github.com/Bias8145/pixel)
# Original source  : https://raw.githubusercontent.com/Bias8145/pixel/main/clone.sh
#
# This is a modified/finalized fork produced during a Lunaris AOSP (Pixel 8
# "shiba") bring-up session: added a community kernel-modules mirror option,
# a GCam (Tensor) source option, full (non-shallow) cloning for kernel
# module repos, corrected shiba/husky default component paths, and
# Tensor-device post-clone build reminders. All core logic, menu flow, and
# design (source_repo/add_component/configure_pixel/execute, etc.) is
# Bias8145's original work — credit to Bias8145 for the base script.
set +u
set -Eo pipefail

readonly C_RESET='\033[0m' C_BOLD='\033[1m' C_CYAN='\033[0;36m' C_GREEN='\033[0;32m' C_RED='\033[0;31m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;34m'

declare -A REPO BRANCH SOURCE SKIP EXISTING
DEVICE=""; DRY_RUN=0; MENU_CHOICE=""; SELECTED_BRANCH=""

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo -e "${C_RED}[ERROR] Missing: $1${C_RESET}"; exit 1; }; }
need_cmd git
need_cmd curl

menu(){
    local title="$1"; shift
    local -a opts=("$@"); local i ans
    MENU_CHOICE=""
    while :; do
        echo -e "\n${C_CYAN}${title}${C_RESET}"
        for i in "${!opts[@]}"; do echo "$((i+1))) ${opts[i]}"; done
        echo "b) Back"; echo "q) Quit"
        read -r -p "> " ans || { echo; MENU_CHOICE=254; return 0; }
        case "$ans" in
            [0-9]*) if ((ans>=1&&ans<=${#opts[@]})); then MENU_CHOICE=$((ans-1)); return 0; fi;;
            b|B) MENU_CHOICE=254; return 0;;
            q|Q) exit 0;;
        esac
        echo -e "${C_RED}Invalid choice.${C_RESET}"
    done
}

path_exists(){ [[ -e "$1" || -L "$1" ]]; }
valid_path(){ [[ "$1" != /* && "$1" != *..* && "$1" =~ ^[A-Za-z0-9._/-]+$ ]]; }
is_vendor_path(){ [[ "$1" == vendor/* ]]; }
is_kernel_path(){ [[ "$1" == *-kernels/* ]]; }
is_camera_path(){ [[ "$1" == vendor/google/camera ]]; }

list_branches(){
    local url="$1"; local -a out=()
    mapfile -t out < <(git ls-remote --heads "$url" 2>/dev/null | awk '{sub("refs/heads/","",$2); print $2}' | sort -V)
    ((${#out[@]})) || return 1
    printf '%s\n' "${out[@]}"
}

pick_branch(){
    local url="$1" component="$2"; local -a bs=(); local i ans
    mapfile -t bs < <(list_branches "$url") || { echo -e "${C_RED}[ERROR] Cannot read branches: $url${C_RESET}"; return 1; }
    echo -e "${C_CYAN}Branches for ${component}:${C_RESET}"
    for i in "${!bs[@]}"; do echo "$((i+1))) ${bs[i]}"; done
    echo "m) Manual branch/tag/ref"; echo "b) Back"
    while :; do
        read -r -p "> " ans || return 254
        case "$ans" in
            [0-9]*) if ((ans>=1&&ans<=${#bs[@]})); then SELECTED_BRANCH="${bs[ans-1]}"; return 0; fi;;
            m|M) read -r -p "Branch/tag/ref: " SELECTED_BRANCH || return 254; [[ -n "$SELECTED_BRANCH" ]] && return 0;;
            b|B) return 254;;
        esac
        echo -e "${C_RED}Invalid branch.${C_RESET}"
    done
}

graphene_repo_for(){
    case "$1" in
        device/google/raviole) echo "https://github.com/GrapheneOS/device_google_raviole.git";;
        device/google/gs101) echo "https://github.com/GrapheneOS/device_google_gs101.git";;
        device/google/gs-common) echo "https://github.com/GrapheneOS/device_google_gs-common.git";;
        device/google/zuma) echo "https://github.com/GrapheneOS/device_google_zuma.git";;
        device/google/raviole-kernels/6.1) echo "https://github.com/GrapheneOS/device_google_raviole-kernels_6.1.git";;
        device/google/shusky) echo "https://github.com/GrapheneOS/device_google_shusky.git";;
        device/google/shusky-kernels/6.1) echo "https://github.com/GrapheneOS/device_google_shusky-kernels_6.1.git";;
        device/google/akita) echo "https://github.com/GrapheneOS/device_google_akita.git";;
        device/google/akita-kernels/6.1) echo "https://github.com/GrapheneOS/device_google_akita-kernels_6.1.git";;
        *) return 1;;
    esac
}

# NEW: community mirror for kernel modules (.ko) — the official LineageOS
# shusky-kernels repo only ships .load/.cfg lists on some branches, not the
# compiled binaries. This mirror (confirmed ~1.5GB, full .ko included) fixes
# "missing and no known rule to make it" ninja errors for gzvm.ko etc.
kernel_mirror_repo_for(){
    case "$1" in
        device/google/shusky-kernels/6.1) echo "https://gitea.com/ivz-prjct/device_google_shusky-kernels.git";;
        *) return 1;;
    esac
}

# NEW: Google Camera (GCam) prebuilt for Tensor devices
gcam_repo_for(){
    case "$1" in
        vendor/google/camera) echo "https://github.com/Libra420T/vendor_google_camera.git";;
        *) return 1;;
    esac
}

repo_name_for(){
    local source="$1" path="$2" p="${2//\//_}"
    case "$source" in
        LineageOS|Bias8145) echo "https://github.com/${source}/android_${p}.git";;
        GrapheneOS) graphene_repo_for "$path";;
        TheMuppets) is_vendor_path "$path" || return 1; echo "https://github.com/TheMuppets/proprietary_${p}.git";;
        KernelMirror) kernel_mirror_repo_for "$path";;
        GCamTensor) gcam_repo_for "$path";;
        *) return 1;;
    esac
}

repo_matches_path(){
    local source="$1" path="$2" url="$3" base expected
    case "$source" in
        LineageOS|Bias8145)
            base="${url##*/}"; base="${base%.git}"; expected="android_${path//\//_}"
            [[ "$base" == "$expected" ]] || return 1;;
        TheMuppets)
            is_vendor_path "$path" || return 1
            base="${url##*/}"; base="${base%.git}"; expected="proprietary_${path//\//_}"
            [[ "$base" == "$expected" ]] || return 1;;
        GrapheneOS)
            [[ -n "$(graphene_repo_for "$path" 2>/dev/null)" && "$url" == "$(graphene_repo_for "$path")" ]] || return 1;;
        KernelMirror)
            [[ -n "$(kernel_mirror_repo_for "$path" 2>/dev/null)" && "$url" == "$(kernel_mirror_repo_for "$path")" ]] || return 1;;
        GCamTensor)
            [[ -n "$(gcam_repo_for "$path" 2>/dev/null)" && "$url" == "$(gcam_repo_for "$path")" ]] || return 1;;
        Custom) return 0;;
        *) return 1;;
    esac
}

show_existing(){
    local path="$1" u b
    path_exists "$path" || return 1
    if [[ -d "$path/.git" || -f "$path/.git" ]]; then
        u="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
        b="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)"
        echo -e "${C_YELLOW}[DETECTED] Existing Git tree: $path${C_RESET}"
        echo "  Remote: ${u:-unknown}"; echo "  Branch: ${b:-detached/unknown}"
    else
        echo -e "${C_YELLOW}[DETECTED] Existing directory/tree: $path${C_RESET}"
    fi
}

handle_existing(){
    local path="$1" choice u b
    show_existing "$path" || return 0
    EXISTING["$path"]=1
    menu "Existing tree detected: $path" "Skip / use existing tree" "Replace existing tree" "Reconfigure source and branch" "Cancel"
    choice="$MENU_CHOICE"
    case "$choice" in
        0)
            SKIP["$path"]=1
            if [[ -d "$path/.git" || -f "$path/.git" ]]; then
                u="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
                b="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)"
                REPO["$path"]="$u"; BRANCH["$path"]="$b"; SOURCE["$path"]="Existing"
            else
                REPO["$path"]=""; BRANCH["$path"]=""; SOURCE["$path"]="Existing"
            fi
            return 0;;
        1) rm -rf -- "$path"; unset 'SKIP[$path]' 'EXISTING[$path]'; return 0;;
        2) unset 'SKIP[$path]'; return 0;;
        3|254) return 254;;
    esac
}

source_repo(){
    local path="$1" component="${1##*/}" choice repo source
    while :; do
        if is_camera_path "$path"; then
            menu "Source for ${path}" "GCam prebuilt (Libra420T, Tensor)" "TheMuppets vendor source" "Bias8145 vendor source" "Manual repository URL"
        elif is_kernel_path "$path"; then
            menu "Source for ${path}" "LineageOS official (config/list only on some branches)" "Community mirror (full compiled .ko — recommended)" "GrapheneOS official" "Bias8145/custom source" "Manual repository URL"
        elif is_vendor_path "$path"; then
            menu "Source for ${path}" "TheMuppets vendor source" "Bias8145 vendor source"
        else
            menu "Source for ${path}" "LineageOS official" "GrapheneOS official" "Bias8145/custom source" "Manual repository URL"
        fi
        choice="$MENU_CHOICE"
        if is_camera_path "$path"; then
            case "$choice" in
                254) return 254;;
                0) repo="$(repo_name_for GCamTensor "$path")" || continue; source="GCamTensor";;
                1) repo="$(repo_name_for TheMuppets "$path")" || continue; source="TheMuppets";;
                2) repo="$(repo_name_for Bias8145 "$path")" || continue; source="Bias8145";;
                3) read -r -p "Repository URL: " repo || return 254; source="Custom";;
                *) continue;;
            esac
        elif is_kernel_path "$path"; then
            case "$choice" in
                254) return 254;;
                0) repo="$(repo_name_for LineageOS "$path")"; source="LineageOS";;
                1) repo="$(repo_name_for KernelMirror "$path")" || { echo -e "${C_YELLOW}[WARN] No known community mirror for $path. Use Manual repository URL.${C_RESET}"; continue; }; source="KernelMirror";;
                2) repo="$(repo_name_for GrapheneOS "$path")" || { echo -e "${C_YELLOW}[WARN] No explicit GrapheneOS mapping for $path. Use Manual repository URL.${C_RESET}"; continue; }; source="GrapheneOS";;
                3) repo="$(repo_name_for Bias8145 "$path")"; source="Bias8145";;
                4) read -r -p "Repository URL: " repo || return 254; source="Custom";;
                *) continue;;
            esac
        elif is_vendor_path "$path"; then
            case "$choice" in
                254) return 254;;
                0) repo="$(repo_name_for TheMuppets "$path")" || continue; source="TheMuppets";;
                1) repo="$(repo_name_for Bias8145 "$path")" || continue; source="Bias8145";;
                *) continue;;
            esac
        else
            case "$choice" in
                254) return 254;;
                0) repo="$(repo_name_for LineageOS "$path")"; source="LineageOS";;
                1) repo="$(repo_name_for GrapheneOS "$path")" || { echo -e "${C_YELLOW}[WARN] No explicit GrapheneOS mapping for $path. Use Manual repository URL.${C_RESET}"; continue; }; source="GrapheneOS";;
                2) repo="$(repo_name_for Bias8145 "$path")"; source="Bias8145";;
                3) read -r -p "Repository URL: " repo || return 254; source="Custom";;
                *) continue;;
            esac
        fi
        [[ -n "$repo" ]] || continue
        if ! repo_matches_path "$source" "$path" "$repo"; then
            echo -e "${C_RED}[ERROR] Repository does not match target path: $repo -> $path${C_RESET}"
            continue
        fi
        if ! git ls-remote --heads "$repo" >/dev/null 2>&1; then
            echo -e "${C_YELLOW}[WARN] Repository unavailable: $repo${C_RESET}"
            continue
        fi
        pick_branch "$repo" "$component" || continue
        echo -e "${C_GREEN}Selected:${C_RESET} $source | $repo | $SELECTED_BRANCH"
        menu "Confirm ${path}" "Confirm" "Choose another source" "Choose another branch"
        case "$MENU_CHOICE" in
            0) REPO["$path"]="$repo"; BRANCH["$path"]="$SELECTED_BRANCH"; SOURCE["$path"]="$source"; unset 'SKIP[$path]'; return 0;;
            1) continue;;
            2) pick_branch "$repo" "$component" || continue;;
            254) return 254;;
        esac
    done
}

add_component(){
    local path="$1"
    valid_path "$path" || { echo -e "${C_RED}[ERROR] Invalid target path: $path${C_RESET}"; return 1; }
    if path_exists "$path"; then handle_existing "$path" || return $?; [[ "${SKIP["$path"]-0}" == 1 ]] && return 0; fi
    source_repo "$path"
}

preflight_existing(){
    local -a found=(); local p
    for p in "$@"; do path_exists "$p" && found+=("$p"); done
    if ((${#found[@]})); then
        echo -e "\n${C_BOLD}${C_YELLOW}========== EXISTING TREES DETECTED ==========${C_RESET}"
        for p in "${found[@]}"; do show_existing "$p"; done
        echo -e "${C_BOLD}${C_YELLOW}=============================================${C_RESET}"
    fi
}

discover_dependencies(){
    local path="$1"
    [[ -n "$path" ]] || return 0
    local url="${REPO["$path"]-}"
    local branch="${BRANCH["$path"]-}"
    local raw tmp repo_path
    [[ -n "$url" && -n "$branch" ]] || return 0
    repo_path="${url#https://github.com/}"
    repo_path="${repo_path%.git}"
    raw="https://raw.githubusercontent.com/${repo_path}/${branch}/lineage.dependencies"
    tmp="$(curl -fsSL "$raw" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || return 0
    echo "$tmp" | sed -n 's/.*"repository":[[:space:]]*"\([^"]*\)".*"target_path":[[:space:]]*"\([^"]*\)".*/\1|\2/p'
}

clone_one(){
    local path="$1"
    [[ -n "$path" ]] || { echo -e "${C_RED}[ERROR] Empty clone path.${C_RESET}"; return 1; }
    local url="${REPO["$path"]-}"
    local branch="${BRANCH["$path"]-}"
    if [[ "${SKIP["$path"]-0}" == 1 ]]; then echo -e "${C_YELLOW}[SKIP] Existing tree: $path${C_RESET}"; return 2; fi
    [[ -n "$url" && -n "$branch" ]] || { echo -e "${C_RED}[ERROR] Invalid clone entry: $path${C_RESET}"; return 1; }
    if path_exists "$path"; then echo -e "${C_YELLOW}[DETECTED] $path still exists; refusing to overwrite.${C_RESET}"; return 1; fi
    echo -e "${C_BLUE}[CLONE]${C_RESET} $url [$branch] -> $path"
    if ((DRY_RUN)); then echo "       git clone -b '$branch' '$url' '$path'"; return 0; fi
    mkdir -p "$(dirname "$path")"
    # NOTE: no --depth=1 here on purpose. During the shiba bring-up, a
    # shallow clone of shusky-kernels silently truncated the repo to ~260KB
    # (list files only, no compiled .ko). A full clone pulled the real
    # content. Shallow clones are fine for most device/vendor trees, but
    # kernel module repos with LFS-like large binaries should be cloned
    # in full to avoid the same trap.
    if is_kernel_path "$path"; then
        git clone --branch "$branch" --single-branch "$url" "$path"
    else
        git clone --depth=1 --branch "$branch" --single-branch "$url" "$path"
    fi
}

show_config(){
    local p
    echo -e "\n${C_BOLD}========== FINAL CONFIGURATION ==========${C_RESET}"
    echo "Device: $DEVICE"
    for p in "${!REPO[@]}"; do
        if [[ "${SKIP["$p"]-0}" == 1 ]]; then
            printf '  %-44s %-12s %s [%s] [EXISTING/SKIP]\n' "$p" "${SOURCE["$p"]}" "${BRANCH["$p"]:-existing}" "${REPO["$p"]:-existing tree}"
        else
            printf '  %-44s %-12s %s [%s]\n' "$p" "${SOURCE["$p"]}" "${BRANCH["$p"]}" "${REPO["$p"]}"
        fi
    done | sort
    echo -e "${C_BOLD}==========================================${C_RESET}"
}

configure_pixel(){
    local codename="$1" p rc
    DEVICE="$codename"; REPO=(); BRANCH=(); SOURCE=(); SKIP=(); EXISTING=()
    local -a defaults=()
    case "$codename" in
        bramble) defaults=("device/google/bramble" "device/google/redbull" "device/google/gs-common" "vendor/google/bramble" "kernel/google/redbull");;
        coral) defaults=("device/google/coral" "device/google/gs-common" "vendor/google/coral" "kernel/google/msm-4.14");;
        flame) defaults=("device/google/coral" "device/google/gs-common" "vendor/google/flame" "kernel/google/msm-4.14");;
        sunfish) defaults=("device/google/sunfish" "device/google/gs-common" "vendor/google/sunfish" "kernel/google/msm-4.14");;
        redfin) defaults=("device/google/redfin" "device/google/redbull" "device/google/gs-common" "vendor/google/redfin" "kernel/google/redbull");;
        oriole) defaults=("device/google/raviole" "device/google/gs101" "device/google/gs-common" "device/google/zuma" "device/google/raviole-kernels/6.1" "vendor/google/oriole");;
        raven) defaults=("device/google/raviole" "device/google/gs101" "device/google/gs-common" "device/google/zuma" "device/google/raviole-kernels/6.1" "vendor/google/raven");;
        # NOTE: "device/google/shiba" removed from defaults. In the actual
        # Lunaris/LineageOS tree, shiba-specific files (device-shiba.mk,
        # aosp_shiba.mk, lineage_shiba.mk) live INSIDE device/google/shusky/,
        # not in a separate device/google/shiba repo. Cloning a non-existent
        # "android_device_google_shiba" repo here would just fail or clone
        # the wrong thing. vendor/google/camera (GCam) added as an optional
        # default — pick "Skip" at the component editor step if you want a
        # pure vanilla build without it.
        shiba) defaults=("device/google/shusky" "device/google/zuma" "device/google/gs-common" "device/google/shusky-kernels/6.1" "vendor/google/shiba" "vendor/google/camera");;
        husky) defaults=("device/google/shusky" "device/google/zuma" "device/google/gs-common" "device/google/shusky-kernels/6.1" "vendor/google/husky" "vendor/google/camera");;
        akita) defaults=("device/google/akita" "device/google/zuma" "device/google/gs-common" "device/google/akita-kernels/6.1" "vendor/google/akita");;
        *) return 1;;
    esac
    echo -e "\n${C_BOLD}${C_CYAN}Preflight: checking existing device trees...${C_RESET}"
    preflight_existing "${defaults[@]}"
    echo -e "${C_BOLD}${C_CYAN}Every component is independent.${C_RESET}"
    echo "Vendor sources: TheMuppets or Bias8145 only (GCam path offers Libra420T too)."
    echo "Kernel module paths: LineageOS official OR community mirror (recommended — see notes)."
    echo "Other components: LineageOS, GrapheneOS, Bias8145 or manual repository."
    for p in "${defaults[@]}"; do
        add_component "$p"; rc=$?
        case "$rc" in 0) ;; 254) return 254;; *) return "$rc";; esac
    done
    while :; do
        show_config
        menu "Component editor" "Add another component/path" "Reconfigure an existing component" "Remove a component" "Auto-discover Lineage dependencies" "Continue"
        case "$MENU_CHOICE" in
            0) read -r -p "Target path: " p || return 254; add_component "$p" || true;;
            1) read -r -p "Target path: " p || return 254; [[ -n "${REPO["$p"]+x}" ]] && { add_component "$p" || true; } || echo "Unknown component.";;
            2) read -r -p "Target path to remove: " p || return 254; unset 'REPO[$p]' 'BRANCH[$p]' 'SOURCE[$p]' 'SKIP[$p]' 'EXISTING[$p]';;
            3) echo -e "${C_CYAN}Dependency candidates:${C_RESET}"; for p in "${!REPO[@]}"; do discover_dependencies "$p" || true; done;;
            4) return 0;;
            254) return 254;;
        esac
    done
}

execute(){
    local p rc failed=0
    show_config
    menu "Execution" "Clone selected repositories" "Dry run" "Edit configuration" "Cancel"
    case "$MENU_CHOICE" in 0) DRY_RUN=0;; 1) DRY_RUN=1;; 2) return 10;; 3|254) return 11;; esac
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        clone_one "$p"; rc=$?
        case "$rc" in 0|2) ;; *) failed=1;; esac
    done < <(printf '%s\n' "${!REPO[@]}" | sort)
    if ((failed==0)); then
        echo -e "${C_GREEN}[SUCCESS] Clone process completed.${C_RESET}"
        case "$DEVICE" in
            shiba|husky|akita)
                echo -e "\n${C_BOLD}${C_YELLOW}========== REMINDERS (Tensor devices) ==========${C_RESET}"
                echo "1) Kernel is PREBUILT (modules only) — do not let 'lunch' try to"
                echo "   sync/compile kernel source. Before lunch/build, run:"
                echo "     export SKIP_KERNEL_BUILD=true"
                echo "2) If building GMS: artifact-path-requirement errors are expected"
                echo "   for several Google/GMS APKs landing in system/ instead of"
                echo "   product/. Add offending paths to"
                echo "   PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST in the device's"
                echo "   actual inherited makefile (for shusky-based devices this is"
                echo "   device/google/shusky/device-shiba.mk — NOT a device/google/shusky/shiba/"
                echo "   subfolder copy, that path is not inherited by the build)."
                echo "3) GCam from vendor/google/camera may fail dexpreopt's"
                echo "   uses-library check (optional libraries declared in its manifest"
                echo "   that the build system doesn't recognize). Fix with:"
                echo "     PRODUCT_BROKEN_VERIFY_USES_LIBRARIES := true"
                echo -e "${C_BOLD}${C_YELLOW}=================================================${C_RESET}"
                ;;
        esac
    else
        echo -e "${C_YELLOW}[PARTIAL] Some components failed.${C_RESET}"
    fi
    return 0
}

main(){
    echo -e "${C_BOLD}=== Android Source Cloner (finalized) ===${C_RESET}"
    echo -e "${C_CYAN}Original script by Bias8145 — https://github.com/Bias8145/pixel${C_RESET}"
    while :; do
        echo -e "\n${C_CYAN}Select device${C_RESET}"
        echo "1) Bramble (Pixel 4a 5G)"
        echo "2) Coral (Pixel 4 XL)"
        echo "3) Flame (Pixel 4)"
        echo "4) Sunfish (Pixel 4a)"
        echo "5) Redfin (Pixel 5)"
        echo "6) Oriole (Pixel 6)"
        echo "7) Raven (Pixel 6 Pro)"
        echo "8) Shiba (Pixel 8)"
        echo "9) Husky (Pixel 8 Pro)"
        echo "10) Akita (Pixel 8a)"
        echo "b) Back"
        echo "q) Quit"
        local device_choice rc
        read -r -p "> " device_choice || exit 0
        case "$device_choice" in
            1) configure_pixel bramble;;
            2) configure_pixel coral;;
            3) configure_pixel flame;;
            4) configure_pixel sunfish;;
            5) configure_pixel redfin;;
            6) configure_pixel oriole;;
            7) configure_pixel raven;;
            8) configure_pixel shiba;;
            9) configure_pixel husky;;
            10) configure_pixel akita;;
            b|B|q|Q) exit 0;;
            *) echo -e "${C_RED}Invalid choice.${C_RESET}"; continue;;
        esac
        rc=$?
        if ((rc!=0&&rc!=254)); then echo -e "${C_YELLOW}[WARN] Configuration returned $rc.${C_RESET}"; fi
        ((rc==254)) && continue
        while :; do
            execute; rc=$?
            ((rc==10)) && continue
            ((rc==11)) && break
            break
        done
    done
}

main "$@"
