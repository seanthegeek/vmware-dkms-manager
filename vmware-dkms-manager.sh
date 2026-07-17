#!/usr/bin/env bash
#
# vmware-dkms-manager.sh
#
# Wraps VMware Workstation's vmmon/vmnet kernel modules as a real DKMS
# package instead of relying on VMware's own vmware-modconfig builder, and
# configures DKMS's own native MOK signing directives so modules are signed
# automatically on every kernel (and, via 'upgrade', every VMware) update.
#
# Distro support:
#   - Debian / Ubuntu (apt)   -- fully supported
#   - Fedora / RHEL / Rocky / AlmaLinux / CentOS (dnf) -- fully supported;
#     EPEL is auto-enabled on RHEL-family systems (not needed on Fedora)
#   - openSUSE (zypper)       -- fully supported
#   - Gentoo (emerge)         -- fully supported; also detects and reuses
#     Portage's MODULES_SIGN_KEY / MODULES_SIGN_CERT in make.conf if set
#   - Void Linux (xbps)       -- fully supported
#   - Arch / Manjaro (pacman) -- supported IF you use the traditional
#     shim + mokutil MOK flow. If your system uses sbctl to sign with your
#     own keys enrolled directly into the UEFI db (no shim/MOK involved),
#     this script detects that and refuses to proceed rather than fighting
#     your existing key setup -- sign the built .ko files with
#     'sbctl sign' yourself in that case.
#   - NOT supported: image-based/immutable systems (Fedora Silverblue or
#     Kinoite, openSUSE Aeon/Kalpa) and NixOS. DKMS's model of writing
#     straight to /usr/src, /var/lib/dkms, /etc/dkms doesn't fit an
#     immutable root or Nix's declarative config -- this script detects
#     both and refuses to proceed rather than leaving a half-working mess.
#
# Why DKMS-native signing instead of distro-specific hooks: Ubuntu's
# apparent "auto-signing" comes from shim-signed staging a MOK at
# /var/lib/shim-signed/mok (via update-secureboot-policy) -- it is NOT
# guaranteed to write anything into /etc/dkms/framework.conf, and not core
# DKMS behavior. Fedora/RHEL ship no such wiring by default (they lean on
# RPM Fusion's separate akmods stack instead). But modern DKMS itself
# (roughly >= 3.0, shipped by all the distros below) has its own native
# default: if framework.conf specifies no signing key, DKMS auto-generates
# and uses one at /var/lib/dkms/mok.key / mok.pub, on any distro.
#
# Best-practice signing approach used here: detect and reuse whatever
# signing key already exists on this system first (an active
# framework.conf entry, Gentoo's make.conf signing vars, or Debian/
# Ubuntu's shim-signed key at /var/lib/shim-signed/mok -- often already
# enrolled) rather than overwriting or duplicating it. Only if nothing is
# configured yet does this script fall back to DKMS's own native default
# location -- never a bespoke path of its own -- so it stays out of the
# way of whatever convention the distro or a prior setup already
# established.
#
# Usage:
#   sudo ./vmware-dkms-manager.sh install    # first time, after installing VMware
#   sudo ./vmware-dkms-manager.sh upgrade    # after upgrading VMware Workstation itself
#   sudo ./vmware-dkms-manager.sh status     # show current state
#   sudo ./vmware-dkms-manager.sh uninstall  # undo everything this script set up
#   ./vmware-dkms-manager.sh version         # print script version
#
# Packages (openssl, mokutil, dkms, and shim-signed where applicable) are
# checked for and installed automatically via the detected package manager.
#
# Copyright 2026 Sean Whalen
# SPDX-License-Identifier: MIT
# Licensed under the MIT License; see the LICENSE file in this repository
# for the full text.
#
set -Eeuo pipefail

# Surface unexpected failures instead of dying silently under set -e.
trap 'echo "ERROR: \"${BASH_COMMAND}\" failed (exit $?) at line ${LINENO}" >&2' ERR

VERSION="0.1.0"

SRC_TAR_DIR="/usr/lib/vmware/modules/source"
DKMS_PKG="vmware-modules"
FRAMEWORK_CONF="/etc/dkms/framework.conf"
FRAMEWORK_MARKER="# added by vmware-dkms-manager.sh"

DISTRO_ID="unknown"
DISTRO_ID_LIKE=""
DISTRO_FAMILY="unknown"
MOK_DIR=""
MOK_PRIV=""
MOK_DER=""
MOK_KEY_SOURCE=""

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run this as root (sudo)." >&2
        exit 1
    fi
}

detect_distro() {
    if [[ -r /etc/os-release ]]; then
        # Read in a subshell: os-release defines VERSION, NAME, etc., which
        # would clobber this script's own globals if sourced directly here.
        local os_fields
        os_fields="$(
            # shellcheck disable=SC1091
            . /etc/os-release 2>/dev/null || true
            echo "${ID:-unknown}|${ID_LIKE:-}"
        )"
        DISTRO_ID="${os_fields%%|*}"
        DISTRO_ID_LIKE="${os_fields##*|}"
    fi

    case " ${DISTRO_ID} ${DISTRO_ID_LIKE} " in
        *" debian "*|*" ubuntu "*)                       DISTRO_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*|*" centos "*)             DISTRO_FAMILY="rhel" ;;
        *" suse "*|*" opensuse "*)                        DISTRO_FAMILY="suse" ;;
        *" arch "*)                                       DISTRO_FAMILY="arch" ;;
        *" gentoo "*)                                     DISTRO_FAMILY="gentoo" ;;
        *" void "*)                                       DISTRO_FAMILY="void" ;;
        *)                                                DISTRO_FAMILY="unknown" ;;
    esac
}

check_immutable_root() {
    # rpm-ostree (Fedora Silverblue/Kinoite, openSUSE Aeon/Kalpa) and NixOS
    # don't work like a traditional mutable root -- DKMS writing straight to
    # /usr/src, /var/lib/dkms, /etc/dkms doesn't survive or apply the way it
    # does everywhere else this script targets. Detect and refuse cleanly
    # rather than leaving behind a half-working mess.
    if [[ -f /run/ostree-booted ]] || command -v rpm-ostree >/dev/null 2>&1; then
        cat >&2 <<'EOF'
Detected an rpm-ostree (image-based) system -- e.g. Fedora Silverblue/Kinoite
or openSUSE Aeon/Kalpa. This script assumes a traditional mutable root where
DKMS can write directly to /usr/src, /var/lib/dkms, and /etc/dkms; that
doesn't hold here.

Consider running VMware Workstation inside a Distrobox/toolbox container
instead, or look into layering an akmod package with 'rpm-ostree install'.

Refusing to proceed.
EOF
        exit 4
    fi
    if [[ -f /etc/NIXOS ]] || command -v nixos-rebuild >/dev/null 2>&1; then
        cat >&2 <<'EOF'
Detected NixOS. Kernel modules there are normally declared in
configuration.nix and built as Nix derivations, not managed by an
imperative DKMS package registration like this script does -- and /etc is
regenerated from the Nix store, so anything this script wrote to
/etc/dkms/framework.conf would be gone on the next rebuild anyway.

See the NixOS wiki's guidance on out-of-tree kernel modules / boot.kernelPatches
instead of running this script.

Refusing to proceed.
EOF
        exit 4
    fi
}

check_sbctl_conflict() {
    # If sbctl is managing Secure Boot with its own enrolled keys and
    # mokutil isn't even present, the MOK/shim flow below doesn't apply --
    # bail out cleanly instead of silently doing the wrong thing.
    command -v sbctl >/dev/null 2>&1 || return 0
    command -v mokutil >/dev/null 2>&1 && return 0

    if sbctl status 2>/dev/null | grep -i "Secure Boot:.*Enabled" >/dev/null; then
        cat >&2 <<'EOF'
Detected sbctl-managed Secure Boot (sbctl is installed, mokutil is not) with
Secure Boot currently enabled. This script's signing flow is built around
mokutil/MOK enrollment -- the shim-based mechanism Debian, Fedora, and RHEL
use by default -- which is a different model than sbctl's direct enrollment
of your own keys into the UEFI db.

If you're using sbctl, sign the DKMS-built modules yourself instead, e.g.:
    sudo sbctl sign -s /var/lib/dkms/vmware-modules/*/*/module/vmmon.ko
    sudo sbctl sign -s /var/lib/dkms/vmware-modules/*/*/module/vmnet.ko

Refusing to proceed automatically to avoid conflicting with your existing
key setup.
EOF
        exit 3
    fi
}

ensure_packages() {
    local missing=()

    case "${DISTRO_FAMILY}" in
        debian)
            command -v openssl >/dev/null 2>&1 || missing+=("openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("dkms")
            dpkg -s shim-signed >/dev/null 2>&1 || missing+=("shim-signed")
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "==> Installing missing packages: ${missing[*]}"
                apt-get update -qq
                apt-get install -y "${missing[@]}"
            else
                echo "==> All required packages already installed"
            fi
            ;;
        rhel)
            command -v openssl >/dev/null 2>&1 || missing+=("openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("dkms")
            # dkms lives in EPEL on RHEL and its clones (Fedora carries it
            # natively). epel-release is only a package on the clones --
            # genuine RHEL needs the Fedora URL -- and non-EPEL
            # fedora-likes (Amazon Linux, Mageia) can't use it at all:
            # fail those with a clear message, not a raw dnf error.
            if [[ " ${missing[*]} " == *" dkms "* && "${DISTRO_ID}" != "fedora" ]] \
                    && ! rpm -q epel-release >/dev/null 2>&1; then
                echo "==> Enabling EPEL (provides dkms on ${DISTRO_ID})"
                if ! dnf install -y epel-release 2>/dev/null; then
                    local rhel_major
                    rhel_major="$(rpm -E %rhel 2>/dev/null || true)"
                    if [[ "${rhel_major}" =~ ^[0-9]+$ ]] \
                            && dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_major}.noarch.rpm"; then
                        # EPEL packages often assume CodeReady Builder/CRB
                        # is enabled; try, but don't fail the run over it.
                        dnf config-manager --set-enabled crb 2>/dev/null \
                            || subscription-manager repos --enable "codeready-builder-for-rhel-${rhel_major}-$(arch)-rpms" 2>/dev/null \
                            || echo "==> NOTE: could not enable CRB/CodeReady Builder; some EPEL dependencies may be missing." >&2
                    else
                        echo "Could not enable EPEL automatically on ${DISTRO_ID}." >&2
                        echo "Enable a repository providing 'dkms' manually, then re-run." >&2
                        exit 1
                    fi
                fi
            fi
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "==> Installing missing packages: ${missing[*]}"
                dnf install -y "${missing[@]}"
            else
                echo "==> All required packages already installed"
            fi
            ;;
        suse)
            command -v openssl >/dev/null 2>&1 || missing+=("openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("dkms")
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "==> Installing missing packages: ${missing[*]}"
                zypper --non-interactive install "${missing[@]}"
            else
                echo "==> All required packages already installed"
            fi
            ;;
        arch)
            command -v openssl >/dev/null 2>&1 || missing+=("openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("dkms")
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "==> Installing missing packages: ${missing[*]}"
                pacman -S --noconfirm --needed "${missing[@]}"
            else
                echo "==> All required packages already installed"
            fi
            ;;
        gentoo)
            command -v openssl >/dev/null 2>&1 || missing+=("dev-libs/openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("sys-boot/mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("sys-kernel/dkms")
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "==> Installing missing packages: ${missing[*]}"
                emerge --ask=n "${missing[@]}"
            else
                echo "==> All required packages already installed"
            fi
            ;;
        void)
            command -v openssl >/dev/null 2>&1 || missing+=("openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("dkms")
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "==> Installing missing packages: ${missing[*]}"
                xbps-install -Sy "${missing[@]}"
            else
                echo "==> All required packages already installed"
            fi
            ;;
        *)
            echo "==> Unrecognized distro (ID=${DISTRO_ID})"
            command -v openssl >/dev/null 2>&1 || missing+=("openssl")
            command -v mokutil >/dev/null 2>&1 || missing+=("mokutil")
            command -v dkms    >/dev/null 2>&1 || missing+=("dkms")
            if [[ ${#missing[@]} -eq 0 ]]; then
                echo "==> All required packages already installed; proceeding"
            # The package names above are only known-correct for managers a
            # recognized family already uses them with (invariant: names
            # differ per family) -- so probe just those. Gentoo's emerge is
            # excluded: its names (dev-libs/openssl, ...) don't match.
            elif command -v apt-get >/dev/null 2>&1; then
                echo "==> Installing missing packages with apt-get: ${missing[*]}"
                apt-get update -qq
                apt-get install -y "${missing[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                echo "==> Installing missing packages with dnf: ${missing[*]}"
                dnf install -y "${missing[@]}"
            elif command -v zypper >/dev/null 2>&1; then
                echo "==> Installing missing packages with zypper: ${missing[*]}"
                zypper --non-interactive install "${missing[@]}"
            elif command -v pacman >/dev/null 2>&1; then
                echo "==> Installing missing packages with pacman: ${missing[*]}"
                pacman -S --noconfirm --needed "${missing[@]}"
            elif command -v xbps-install >/dev/null 2>&1; then
                echo "==> Installing missing packages with xbps: ${missing[*]}"
                xbps-install -Sy "${missing[@]}"
            else
                echo "MISSING: ${missing[*]} -- no supported package manager found; install them yourself, then re-run." >&2
                exit 1
            fi
            ;;
    esac
}

read_framework_conf_var() {
    local var="$1" f
    # dkms sources framework.conf first, then framework.conf.d/*.conf in
    # glob order, with later files overriding earlier ones -- mirror that
    # by taking the last match across the same sequence. "not set" must
    # yield empty + success: grep exits 1 on no match, and under pipefail
    # that would kill the whole script at the call site.
    for f in "${FRAMEWORK_CONF}" "${FRAMEWORK_CONF}.d"/*.conf; do
        [[ -f "${f}" ]] || continue
        grep -E "^[[:space:]]*${var}=" "${f}" 2>/dev/null || true
    done \
        | tail -n1 \
        | sed -E "s/^[[:space:]]*${var}=//; s/^[\"']//; s/[\"']\$//" \
        || true
}

read_portage_sign_vars() {
    local mc="/etc/portage/make.conf"
    [[ -f "${mc}" ]] || return 0
    ( set +u; unset MODULES_SIGN_KEY MODULES_SIGN_CERT
      # shellcheck disable=SC1090
      . "${mc}" 2>/dev/null || true
      echo "${MODULES_SIGN_KEY:-}|${MODULES_SIGN_CERT:-}" )
}

determine_mok_paths() {
    # Best practice: reuse whatever signing key already exists on this
    # system rather than asserting our own opinion. Checked in order:
    #   1. Active mok_signing_key/mok_certificate in framework.conf (any
    #      pre-existing config, e.g. set up for another DKMS module).
    #   2. Gentoo: MODULES_SIGN_KEY/MODULES_SIGN_CERT in make.conf.
    #   3. Ubuntu/Debian: shim-signed's key at /var/lib/shim-signed/mok --
    #      staged there by update-secureboot-policy and often already
    #      enrolled, but NOT necessarily referenced from framework.conf.
    #   4. Only then DKMS's own native default location --
    #      /var/lib/dkms/mok.key + mok.pub, used automatically by
    #      DKMS >= ~3.0 on every distro that ships it, not a path we're
    #      inventing.
    local existing_key existing_cert
    existing_key="$(read_framework_conf_var mok_signing_key)"
    existing_cert="$(read_framework_conf_var mok_certificate)"

    if [[ -z "${existing_key}" && "${DISTRO_FAMILY}" == "gentoo" ]]; then
        local portage_vars
        portage_vars="$(read_portage_sign_vars)"
        local key_part="${portage_vars%%|*}"
        local cert_part="${portage_vars##*|}"
        if [[ -n "${key_part}" && -n "${cert_part}" ]]; then
            existing_key="${key_part}"
            existing_cert="${cert_part}"
        fi
    fi

    if [[ -n "${existing_key}" && -n "${existing_cert}" ]]; then
        MOK_PRIV="${existing_key}"
        MOK_DER="${existing_cert}"
        MOK_KEY_SOURCE="existing config"
    elif [[ -f /var/lib/shim-signed/mok/MOK.priv \
            && -f /var/lib/shim-signed/mok/MOK.der ]]; then
        MOK_PRIV="/var/lib/shim-signed/mok/MOK.priv"
        MOK_DER="/var/lib/shim-signed/mok/MOK.der"
        MOK_KEY_SOURCE="shim-signed MOK"
    else
        MOK_PRIV="/var/lib/dkms/mok.key"
        MOK_DER="/var/lib/dkms/mok.pub"
        MOK_KEY_SOURCE="DKMS native default"
    fi
    MOK_DIR="$(dirname "${MOK_PRIV}")"
}

require_source_tarballs() {
    if [[ ! -f "${SRC_TAR_DIR}/vmmon.tar" || ! -f "${SRC_TAR_DIR}/vmnet.tar" ]]; then
        echo "Could not find ${SRC_TAR_DIR}/vmmon.tar and vmnet.tar." >&2
        echo "Install or launch VMware Workstation at least once first so it stages its module source." >&2
        exit 1
    fi
}

detect_vmware_version() {
    # "VMware Workstation 17.6.5 build-24583293" -> "17.6.5-24583293"
    # Newer releases drop the "build-" prefix ("26.0.0 25388281") -- accept
    # both. Returns 1 (not exit) so cmd_status's fallback can catch it;
    # install/upgrade abort via set -e at the call site.
    local raw ver
    raw="$(vmware -v 2>/dev/null || true)"
    if [[ -z "${raw}" ]]; then
        echo "Could not run 'vmware -v' to detect the installed version." >&2
        return 1
    fi
    ver="$(echo "${raw}" \
        | grep -oE '[0-9][0-9A-Za-z.]*[[:space:]]+(build-)?[0-9]+' \
        | sed -E 's/[[:space:]]+(build-)?/-/' \
        || true)"
    if [[ -z "${ver}" ]]; then
        echo "Could not parse a version from 'vmware -v' output: ${raw}" >&2
        return 1
    fi
    echo "${ver}"
}

current_registered_version() {
    # Stop at ',' OR ':' -- modern dkms prints "pkg/version: state" with no
    # comma, so [^,]* alone swallows the state suffix into the version.
    dkms status -m "${DKMS_PKG}" 2>/dev/null \
        | sed -n "s/^${DKMS_PKG}\/\([^,:]*\).*/\1/p" \
        | head -n1 \
        || true
}

write_dkms_conf() {
    local ver="$1" src_dir="$2"
    cat > "${src_dir}/dkms.conf" <<EOF
PACKAGE_NAME="${DKMS_PKG}"
PACKAGE_VERSION="${ver}"

CLEAN="make -C vmmon-only clean; make -C vmnet-only clean"

# One MAKE[0] must build BOTH modules: MAKE[#>0] entries are alternatives
# selected by MAKE_MATCH[#] kernel regexes and are IGNORED without one --
# they are not a sequence. VM_UNAME overrides VMware's 'uname -r' default
# so autoinstall builds target the kernel being installed for, not the
# one currently running.
MAKE[0]="make -C vmmon-only VM_UNAME=\${kernelver} && make -C vmnet-only VM_UNAME=\${kernelver}"

BUILT_MODULE_NAME[0]="vmmon"
BUILT_MODULE_LOCATION[0]="vmmon-only"
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="vmnet"
BUILT_MODULE_LOCATION[1]="vmnet-only"
DEST_MODULE_LOCATION[1]="/updates/dkms"

AUTOINSTALL="yes"
EOF
}

stage_source() {
    local ver="$1"
    local src_dir="/usr/src/${DKMS_PKG}-${ver}"

    rm -rf "${src_dir}"
    mkdir -p "${src_dir}"
    tar -xf "${SRC_TAR_DIR}/vmmon.tar" -C "${src_dir}"
    tar -xf "${SRC_TAR_DIR}/vmnet.tar" -C "${src_dir}"

    if [[ ! -d "${src_dir}/vmmon-only" || ! -d "${src_dir}/vmnet-only" ]]; then
        echo "Expected vmmon-only/ and vmnet-only/ after extraction; layout may have changed." >&2
        exit 1
    fi

    write_dkms_conf "${ver}" "${src_dir}"
}

remove_old_registration() {
    local old_ver="$1"
    if [[ -n "${old_ver}" ]]; then
        echo "==> Removing old DKMS registration: ${DKMS_PKG}/${old_ver}"
        dkms remove -m "${DKMS_PKG}" -v "${old_ver}" --all 2>/dev/null || true
        rm -rf "/usr/src/${DKMS_PKG}-${old_ver}"
    fi
}

purge_legacy_unsigned_modules() {
    # Modules previously built by vmware-modconfig live in .../misc and are
    # never signed. Once DKMS-built, signed copies exist under .../updates/dkms,
    # remove the stale misc/ copies so nothing ambiguous is left on disk.
    local kver
    kver="$(uname -r)"
    local misc_dir="/lib/modules/${kver}/misc"
    for mod in vmmon vmnet; do
        if [[ -f "${misc_dir}/${mod}.ko" ]]; then
            echo "==> Removing legacy unsigned ${misc_dir}/${mod}.ko"
            rm -f "${misc_dir}/${mod}.ko"
        fi
    done
}

secure_boot_enabled() {
    command -v mokutil >/dev/null 2>&1 || return 1
    mokutil --sb-state 2>/dev/null | grep -i "SecureBoot enabled" >/dev/null
}

require_dkms_signing_support() {
    # dkms's native MOK signing directives (mok_signing_key etc.) arrived
    # in 3.0; older 2.8.x (openSUSE Leap 15.5, Ubuntu <= 22.04, Debian 11)
    # silently ignores them and builds UNSIGNED modules -- fail up front
    # with the real reason instead of at signature verification.
    local dv
    dv="$(dkms --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
    if [[ -z "${dv}" ]]; then
        echo "==> WARNING: could not parse 'dkms --version'; assuming it supports native signing." >&2
        return 0
    fi
    if [[ "$(printf '%s\n' 3.0 "${dv}" | sort -V | head -n1)" != "3.0" ]]; then
        echo "dkms ${dv} is too old for native MOK signing (needs >= 3.0)." >&2
        echo "With Secure Boot enabled, modules built now would be unsigned and refused by the kernel." >&2
        echo "Upgrade dkms (or the distro release providing it), then re-run." >&2
        exit 1
    fi
}

shim_present() {
    # MokManager only runs when the system boots via shim; look for shim
    # binaries on the usual ESP mountpoints.
    local d
    for d in /boot/efi /efi /boot; do
        [[ -d "${d}" ]] || continue
        if find "${d}" -maxdepth 4 -iname 'shim*.efi' 2>/dev/null | grep . >/dev/null; then
            return 0
        fi
    done
    return 1
}

create_mok_if_missing() {
    if [[ -f "${MOK_PRIV}" && -f "${MOK_DER}" ]]; then
        return 0
    fi
    if [[ -f "${MOK_PRIV}" || -f "${MOK_DER}" ]]; then
        echo "Found only one half of the MOK pair (${MOK_PRIV} / ${MOK_DER})." >&2
        echo "Refusing to overwrite the surviving file -- restore or remove it, then re-run." >&2
        exit 1
    fi

    echo "==> No MOK signing key found at ${MOK_PRIV} -- generating one"
    mkdir -p "${MOK_DIR}"
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "${MOK_PRIV}" -outform DER -out "${MOK_DER}" \
        -nodes -days 36500 -subj "/CN=DKMS module signing key/"
    chmod 600 "${MOK_PRIV}"
    chmod 644 "${MOK_DER}"
    echo "==> Key created."
}

ensure_dkms_signing_config() {
    if [[ "${MOK_KEY_SOURCE}" == existing* ]]; then
        echo "==> Reusing this system's existing DKMS signing config (${MOK_PRIV})"
        return 0
    fi

    # Nothing was configured -- point framework.conf explicitly at the
    # selected key (shim-signed's, or DKMS's own default location). (Left
    # implicit, some DKMS versions have shipped with bugs around
    # auto-signing without an explicit entry -- see Debian bug #1019425 --
    # so we write it out rather than relying on it.)
    echo "==> No mok_signing_key set in ${FRAMEWORK_CONF} -- writing one pointing at ${MOK_PRIV} (${MOK_KEY_SOURCE})"
    mkdir -p "$(dirname "${FRAMEWORK_CONF}")"
    touch "${FRAMEWORK_CONF}"

    if grep -qF "${FRAMEWORK_MARKER}" "${FRAMEWORK_CONF}" 2>/dev/null; then
        sed -i "/${FRAMEWORK_MARKER}/,+3d" "${FRAMEWORK_CONF}"
    fi

    cat >> "${FRAMEWORK_CONF}" <<EOF
${FRAMEWORK_MARKER}
mok_signing_key="${MOK_PRIV}"
mok_certificate="${MOK_DER}"
sign_file="/lib/modules/\${kernelver}/build/scripts/sign-file"
EOF
    echo "==> DKMS signing config written to ${FRAMEWORK_CONF}"
}

mok_is_enrolled() {
    # Compare by SHA1 fingerprint rather than /proc/keys or subject text --
    # /proc/keys truncates the key-type column ("asymmetri") and subject
    # string formatting between openssl and mokutil isn't guaranteed to
    # match, so the fingerprint is the only reliable comparison.
    local fpr
    fpr="$(openssl x509 -in "${MOK_DER}" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//')"
    [[ -n "${fpr}" ]] || return 1
    # No 'grep -q' here: -q exits at first match, the producer can catch
    # SIGPIPE mid-write, and pipefail then fails the pipeline even though
    # the fingerprint matched (measured ~45% of runs). Reading to EOF and
    # discarding stdout keeps the exit semantics without the race.
    mokutil --list-enrolled 2>/dev/null | grep -i "${fpr}" >/dev/null
}

mok_import_pending() {
    local fpr
    fpr="$(openssl x509 -in "${MOK_DER}" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//')"
    [[ -n "${fpr}" ]] || return 1
    mokutil --list-new 2>/dev/null | grep -i "${fpr}" >/dev/null
}

ensure_mok() {
    if ! secure_boot_enabled; then
        echo "==> Secure Boot is not enabled -- module signing isn't required, skipping MOK setup."
        return 0
    fi

    require_dkms_signing_support
    create_mok_if_missing
    ensure_dkms_signing_config

    if mok_is_enrolled; then
        echo "==> MOK key is enrolled and trusted by the running kernel."
        return 0
    fi

    if mok_import_pending; then
        echo "A MOK enrollment is already pending but hasn't been completed yet."
        echo "Reboot now, and at the blue MokManager screen choose:"
        echo "  Enroll MOK -> Continue -> Yes -> enter your password -> reboot"
        echo "Then re-run: $0 $CMD_NAME"
        exit 2
    fi

    if ! shim_present; then
        echo "No shim bootloader found on the EFI system partition." >&2
        echo "MOK enrollment needs the system to boot via shim (MokManager runs from it);" >&2
        echo "staging an import here would never complete. Install shim (e.g. shim-signed)" >&2
        echo "or sign the built modules with your platform's own keys (e.g. sbctl) instead." >&2
        exit 1
    fi

    echo "==> Enrolling the new MOK key with mokutil (you'll be asked to set a one-time password)"
    mokutil --import "${MOK_DER}"
    echo

    # Don't take mokutil's word for it -- verify what actually happened.
    # (mokutil exits 0 but stages nothing when the key is already enrolled.)
    if mok_is_enrolled; then
        echo "==> Key is already enrolled -- no reboot needed, continuing."
        return 0
    fi
    if ! mok_import_pending; then
        echo "mokutil --import did not stage an enrollment, and the key is not enrolled." >&2
        echo "Inspect with 'mokutil --list-new' and 'mokutil --list-enrolled', then re-run." >&2
        exit 1
    fi
    echo "MOK import staged. A REBOOT is required to complete enrollment."
    echo "At the blue MokManager screen choose:"
    echo "  Enroll MOK -> Continue -> Yes -> enter the password you just set -> reboot"
    echo "Then re-run: $0 $CMD_NAME"
    exit 2
}

build_install_load() {
    local ver="$1"

    echo "==> Registering ${DKMS_PKG}/${ver} with DKMS"
    dkms add -m "${DKMS_PKG}" -v "${ver}"

    echo "==> Building ${DKMS_PKG}/${ver}"
    dkms build -m "${DKMS_PKG}" -v "${ver}"

    # Purge BEFORE 'dkms install': leftover vmware-modconfig modules in
    # .../misc make dkms refuse to install its copies ("already installed
    # (unversioned module)") -- and it exits 0 doing so, leaving no signed
    # modules in place.
    purge_legacy_unsigned_modules

    echo "==> Installing ${DKMS_PKG}/${ver} (signed via DKMS's configured MOK)"
    dkms install -m "${DKMS_PKG}" -v "${ver}"

    echo "==> Verifying signatures"
    for mod in vmmon vmnet; do
        if modinfo "${mod}" 2>/dev/null | grep '^signer:' >/dev/null; then
            modinfo "${mod}" | grep -E '^signer:|^sig_key:'
        elif secure_boot_enabled; then
            echo "  ${mod}: NOT SIGNED -- Secure Boot would refuse to load it; check 'dkms build' output above" >&2
            exit 1
        else
            echo "  ${mod}: not signed (Secure Boot disabled -- not required)"
        fi
    done

    echo "==> Reloading modules"
    depmod -a
    if ! modprobe -r vmnet vmmon 2>/dev/null \
            && lsmod | grep -E '^vmmon|^vmnet' >/dev/null; then
        echo "==> WARNING: old vmmon/vmnet are still loaded (in use by running VMs?)." >&2
        echo "    The freshly signed modules take effect once the VMs stop and the modules reload (or after a reboot)." >&2
    fi
    modprobe vmmon
    modprobe vmnet

    echo "==> Restarting VMware services"
    # Note the grouping: without braces this parses as (a || b) && c and
    # runs the fallback even when systemctl succeeded.
    systemctl restart vmware.service 2>/dev/null \
        || { vmware-networks --stop 2>/dev/null || true; vmware-networks --start; }

    echo "==> Done. ${DKMS_PKG}/${ver} is now DKMS-managed."
    echo "    Future kernel upgrades will rebuild and sign it automatically --"
    echo "    no further action needed unless VMware Workstation itself is upgraded."
    echo
    cmd_status
}

cmd_install() {
    require_root
    detect_distro
    echo "==> Detected distro: ${DISTRO_ID} (family: ${DISTRO_FAMILY})"
    check_immutable_root
    check_sbctl_conflict
    echo "==> Environment checks passed (mutable root, no sbctl conflict)"
    ensure_packages
    determine_mok_paths
    echo "==> Signing key: ${MOK_PRIV} (source: ${MOK_KEY_SOURCE})"
    ensure_mok
    require_source_tarballs
    echo "==> Found VMware module source in ${SRC_TAR_DIR}"

    local existing
    existing="$(current_registered_version)"
    if [[ -n "${existing}" ]]; then
        # "installed (Differences between built and installed modules)"
        # means dkms marked it installed WITHOUT copying the modules (seen
        # when legacy misc/ copies blocked the install) -- treat anything
        # but a clean "installed" as incomplete.
        if dkms status -m "${DKMS_PKG}" -v "${existing}" 2>/dev/null \
                | grep -i ": installed" | grep -vi "differences" >/dev/null; then
            echo "${DKMS_PKG} is already registered and installed at version ${existing}."
            echo "Use '$0 upgrade' if VMware Workstation has since been upgraded."
            echo
            cmd_status
            exit 0
        fi
        # Registered but never finished building/installing -- a previous
        # run failed partway. Clear it and start over.
        echo "==> Found incomplete registration ${DKMS_PKG}/${existing} -- removing it and retrying"
        remove_old_registration "${existing}"
    fi

    local ver
    ver="$(detect_vmware_version)"
    echo "==> Detected VMware Workstation version: ${ver}"
    stage_source "${ver}"
    build_install_load "${ver}"
}

cmd_upgrade() {
    require_root
    detect_distro
    echo "==> Detected distro: ${DISTRO_ID} (family: ${DISTRO_FAMILY})"
    check_immutable_root
    check_sbctl_conflict
    echo "==> Environment checks passed (mutable root, no sbctl conflict)"
    ensure_packages
    determine_mok_paths
    echo "==> Signing key: ${MOK_PRIV} (source: ${MOK_KEY_SOURCE})"
    ensure_mok
    require_source_tarballs
    echo "==> Found VMware module source in ${SRC_TAR_DIR}"

    local old_ver new_ver
    old_ver="$(current_registered_version)"
    new_ver="$(detect_vmware_version)"

    if [[ -z "${old_ver}" ]]; then
        echo "No existing ${DKMS_PKG} registration found -- running initial install instead."
        cmd_install
        return
    fi

    if [[ "${old_ver}" == "${new_ver}" ]]; then
        echo "Installed VMware version (${new_ver}) matches the registered DKMS version."
        echo "Nothing to do. Pass 'install' if you just want to force a rebuild."
        exit 0
    fi

    echo "==> VMware Workstation upgraded: ${old_ver} -> ${new_ver}"
    stage_source "${new_ver}"
    remove_old_registration "${old_ver}"
    build_install_load "${new_ver}"
}

cmd_status() {
    detect_distro
    determine_mok_paths

    if [[ "${EUID}" -ne 0 ]]; then
        echo "(running unprivileged -- Secure Boot/MOK enrollment info may be incomplete; run with sudo for authoritative results)"
        echo
    fi

    echo "Distro:"
    echo "  ID=${DISTRO_ID} (family: ${DISTRO_FAMILY})"
    echo

    echo "Required packages:"
    for pkg_bin in openssl mokutil dkms; do
        if command -v "${pkg_bin}" >/dev/null 2>&1; then
            echo "  ${pkg_bin}: installed"
        else
            echo "  ${pkg_bin}: MISSING (run '$0 install' to auto-install)"
        fi
    done
    if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        if dpkg -s shim-signed >/dev/null 2>&1; then
            echo "  shim-signed: installed"
        else
            echo "  shim-signed: MISSING (run '$0 install' to auto-install)"
        fi
    fi
    if command -v sbctl >/dev/null 2>&1; then
        echo "  sbctl: present (${MOK_DIR}-based flow will be skipped if mokutil is absent and Secure Boot is on)"
    fi
    echo

    echo "MOK key location: ${MOK_DIR} (${MOK_KEY_SOURCE})"
    echo "Secure Boot:"
    if ! command -v mokutil >/dev/null 2>&1; then
        echo "  unknown (mokutil not installed -- run '$0 install' to set up)"
    elif secure_boot_enabled; then
        echo "  enabled"
        if [[ -f "${MOK_PRIV}" && -f "${MOK_DER}" ]]; then
            if mok_is_enrolled; then
                echo "  MOK key present and enrolled"
            elif mok_import_pending; then
                echo "  MOK key present, enrollment PENDING reboot"
            else
                echo "  MOK key present, NOT enrolled"
            fi
        else
            echo "  no MOK key created yet"
        fi
    else
        echo "  disabled (signing not required)"
    fi
    echo
    echo "Registered DKMS state:"
    local reg
    reg="$(dkms status -m "${DKMS_PKG}" 2>/dev/null || true)"
    echo "${reg:-  (not registered)}"
    echo
    echo "Installed VMware version:"
    detect_vmware_version || echo "  (vmware -v not available)"
    echo
    echo "Loaded modules:"
    lsmod | grep -E '^vmmon|^vmnet' || echo "  (not loaded)"
    echo
    echo "Signature status:"
    for mod in vmmon vmnet; do
        modinfo "${mod}" 2>/dev/null | grep -E '^signer:|^sig_key:' \
            || echo "  ${mod}: not loaded or not signed"
    done
}

cmd_uninstall() {
    require_root
    detect_distro
    echo "==> Detected distro: ${DISTRO_ID} (family: ${DISTRO_FAMILY})"

    # Deliberately independent of VMware itself: works from dkms state and
    # the framework.conf marker alone, so it can clean up even after
    # VMware Workstation has already been uninstalled.
    local ver
    ver="$(current_registered_version)"
    if [[ -n "${ver}" ]]; then
        echo "==> Unloading modules (if loaded)"
        if ! modprobe -r vmnet vmmon 2>/dev/null \
                && lsmod | grep -E '^vmmon|^vmnet' >/dev/null; then
            echo "==> WARNING: vmmon/vmnet still loaded (in use by running VMs?) -- they unload on reboot." >&2
        fi
        remove_old_registration "${ver}"
        depmod -a
    else
        echo "==> No ${DKMS_PKG} DKMS registration found -- nothing to unregister"
    fi

    if [[ -f "${FRAMEWORK_CONF}" ]] \
            && grep -qF "${FRAMEWORK_MARKER}" "${FRAMEWORK_CONF}" 2>/dev/null; then
        echo "==> Removing this script's block from ${FRAMEWORK_CONF}"
        sed -i "/${FRAMEWORK_MARKER}/,+3d" "${FRAMEWORK_CONF}"
    else
        echo "==> No entries from this script in ${FRAMEWORK_CONF}"
    fi

    echo "==> Done. Not removed (on purpose):"
    echo "    - signing keys (other DKMS modules may be signed with them;"
    echo "      a MOK enrollment lives in firmware -- 'mokutil --delete' if you want it gone)"
    echo "    - the dkms/mokutil/openssl packages"
    if command -v vmware >/dev/null 2>&1; then
        echo "    VMware Workstation is still installed: it will rebuild its own (unsigned)"
        echo "    modules via vmware-modconfig on next start; re-run '$0 install' any time"
        echo "    to put them back under DKMS."
    fi
}

CMD_NAME="${1:-}"
case "${CMD_NAME}" in
    install)   cmd_install ;;
    upgrade)   cmd_upgrade ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    version|--version|-V)
        echo "vmware-dkms-manager ${VERSION}"
        ;;
    *)
        echo "Usage: $0 {install|upgrade|status|uninstall|version}" >&2
        exit 1
        ;;
esac

