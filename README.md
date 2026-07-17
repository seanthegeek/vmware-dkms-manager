# vmware-dkms-manager

Wraps VMware Workstation's `vmmon`/`vmnet` kernel modules as a proper DKMS
package, so they get rebuilt **and signed** automatically on every kernel
upgrade — matching how VirtualBox's `virtualbox-dkms` already behaves,
without needing a manual re-sign after every `apt`/`dnf`/kernel update.

## Why this exists

VMware ships its own build tool, `vmware-modconfig`, which compiles
`vmmon`/`vmnet` from source but never hooks into DKMS. With UEFI Secure Boot
enabled, that means every kernel update leaves the modules unsigned and
unloadable until someone manually reruns `sign-file` by hand.

This script fixes that by registering `vmmon`/`vmnet` as a real DKMS
package (`vmware-modules`), which lets two things happen automatically from
then on:

- **Rebuilding** on every kernel update — via the kernel's own
  `postinst`/hook mechanism that DKMS installs for itself.
- **Signing** on every rebuild — via DKMS's native `mok_signing_key` /
  `mok_certificate` / `sign_file` support in `/etc/dkms/framework.conf`,
  which every modern DKMS (≈3.0+) ships with, on every distro below.

## Requirements

- VMware Workstation already installed at least once, so
  `/usr/lib/vmware/modules/source/{vmmon,vmnet}.tar` exist.
- Everything else (`dkms`, `mokutil`, `openssl`, and `shim-signed` where
  applicable) is detected and installed automatically.

## Usage

```bash
sudo ./vmware-dkms-manager.sh install   # first time, after installing VMware
sudo ./vmware-dkms-manager.sh upgrade   # after upgrading VMware Workstation itself
sudo ./vmware-dkms-manager.sh status    # inspect current state, read-only
sudo ./vmware-dkms-manager.sh uninstall # undo everything this script set up
./vmware-dkms-manager.sh version        # print script version
```

**`install`** — registers `vmmon`/`vmnet` with DKMS, builds, signs, loads.
Run it once. If Secure Boot needs a new key enrolled, the script generates
one, stages the enrollment with `mokutil --import`, and exits asking you to
reboot and complete it at the blue MokManager screen (**Enroll MOK →
Continue → Yes → your password → reboot**). Re-run the same command
afterward to finish.

**`upgrade`** — run by hand after upgrading VMware Workstation itself.
VMware ships as a `.bundle` installer, not a distro package, so there's no
hook point to automate this the way kernel updates are automated. This
detects the version change (via `vmware -v`), re-extracts the new module
source, and re-registers with DKMS.

**`status`** — shows distro detection, package/MOK state, Secure Boot
state, DKMS registration, loaded modules, and signature info. Never
modifies anything.

**`uninstall`** — removes everything this script set up: the DKMS
registration and its built modules, the staged source under `/usr/src`,
and the block it added to `/etc/dkms/framework.conf`. Works whether or not
VMware Workstation is still installed — it reads state from DKMS, not from
VMware. Deliberately left in place: signing keys (other DKMS modules may
be signed with them, and a MOK enrollment lives in firmware — use
`mokutil --delete` if you really want it gone) and the installed
`dkms`/`mokutil`/`openssl` packages.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (or nothing to do) |
| `1` | Generic error (missing root, missing VMware source, build/signing failure) |
| `2` | MOK key created or import staged — **reboot required**, then re-run |
| `3` | `sbctl`-managed Secure Boot detected — refused, see below |
| `4` | Immutable/atomic root or NixOS detected — refused, see below |

## Signing key: how it's chosen

The script never assumes it owns Secure Boot signing on your system. On
every run, `determine_mok_paths` checks, **in order**:

1. Does `/etc/dkms/framework.conf` already set `mok_signing_key` /
   `mok_certificate` (uncommented)? Any pre-existing config — yours or a
   distro's — is reused as-is.
2. On Gentoo: does `/etc/portage/make.conf` set `MODULES_SIGN_KEY` /
   `MODULES_SIGN_CERT`? (DKMS ≥3.1.6 on Gentoo auto-detects these.)
3. Do `/var/lib/shim-signed/mok/MOK.priv` and `MOK.der` both exist? That's
   where Debian/Ubuntu's `shim-signed` package stages its key (via
   `update-secureboot-policy`) — typically already enrolled — **without**
   necessarily writing a `framework.conf` entry, so it's checked directly.
4. Otherwise, fall back to DKMS's own built-in default location —
   `/var/lib/dkms/mok.key` / `mok.pub` — used automatically by any modern
   DKMS regardless of distro. Never a bespoke path invented by this script.

Whichever key is in play, it's shared system-wide: any other DKMS module
(VirtualBox, NVIDIA, ZFS, etc.) already using that same config will keep
working, and future ones will use it too. Nothing here creates a
VMware-only key unless nothing else was configured yet.

Native DKMS signing requires **dkms ≥ 3.0** (e.g. openSUSE Leap ≥ 15.6,
Ubuntu ≥ 24.04, Debian ≥ 12). Older 2.8.x releases silently ignore the
signing directives and would build unsigned modules, so with Secure Boot
enabled the script checks the dkms version and refuses with a clear
message rather than producing modules the kernel would reject.

## Distro support

| Distro family | Package manager | Status |
| --- | --- | --- |
| Debian / Ubuntu | `apt` | Fully supported |
| Fedora / RHEL / Rocky / Alma / CentOS | `dnf` | Fully supported (EPEL auto-enabled where needed) |
| openSUSE | `zypper` | Fully supported |
| Gentoo | `emerge` | Fully supported, respects Portage sign-key vars |
| Void Linux | `xbps` | Fully supported |
| Arch / Manjaro / EndeavourOS | `pacman` | Supported **if** using traditional shim + `mokutil`. Refused (exit `3`) if `sbctl`-only Secure Boot is detected — see below. |
| Mint, Pop!_OS, Zorin, Nobara, CachyOS, etc. | — | Covered automatically via `ID_LIKE` matching to their parent family |
| Fedora Silverblue/Kinoite, openSUSE Aeon/Kalpa | — | **Not supported** — image-based root, refused (exit `4`) |
| NixOS | — | **Not supported** — declarative config model, refused (exit `4`) |
| Alpine, Slackware | — | Not implemented (musl/no dependency-resolving package manager make VMware Workstation an unlikely fit anyway) |

### The `sbctl` case (mainly Arch)

Some systems sign Secure Boot artifacts directly with their own keys
enrolled into the UEFI `db`, via `sbctl`, instead of using the
shim + MOK/`mokutil` mechanism this script automates. If `sbctl` is present,
`mokutil` is absent, and Secure Boot is on, the script assumes that's your
setup and refuses (exit `3`) rather than installing `mokutil` and fighting
your existing keys. Sign the built modules yourself in that case:

```bash
sudo sbctl sign -s /var/lib/dkms/vmware-modules/*/*/module/vmmon.ko
sudo sbctl sign -s /var/lib/dkms/vmware-modules/*/*/module/vmnet.ko
```

If both `sbctl` and `mokutil` are present, the script assumes a hybrid or
legacy setup and proceeds with the normal MOK flow.

## What it touches

- `/usr/src/vmware-modules-<version>/` — staged module source (from
  VMware's own `vmmon.tar`/`vmnet.tar`) plus a generated `dkms.conf`.
- `/etc/dkms/framework.conf` — only appended to (under a marked, idempotent
  block) if no existing signing config was found.
- The MOK key/cert location determined above — only generated if missing.
- `/lib/modules/$(uname -r)/misc/{vmmon,vmnet}.ko` — removed if present,
  since these are the old unsigned copies from `vmware-modconfig`, now
  superseded by the signed DKMS-built ones.

## Troubleshooting

- **`status` shows "MOK key present, NOT enrolled"** — you generated a key
  previously but never completed the reboot/MokManager step. Re-run
  `install` or `upgrade`; it'll detect the pending state and prompt again.
- **Modules show as built but won't load** — check `dmesg | grep -i
  'vmmon\|vmnet\|lockdown\|denied'` and confirm `modinfo vmmon | grep
  signer` shows your key.
- **After a distro upgrade or reinstall, keys look "gone"** — Secure Boot
  MOK enrollment lives in UEFI NVRAM, not on disk; a fresh OS install starts
  over. `status` will show accurately whether a key exists and whether it's
  enrolled.
