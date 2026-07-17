# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-17

Initial release.

### Added

- `install` command: registers VMware Workstation's `vmmon`/`vmnet` modules
  as a real DKMS package so they rebuild and get signed automatically on
  every kernel update.
- `upgrade` command: re-registers the modules after VMware Workstation
  itself is upgraded (detects the version change via `vmware -v`).
- `status` command: read-only report of distro, packages, Secure Boot/MOK
  state, DKMS registration, loaded modules, and module signatures.
- `uninstall` command: removes the DKMS registration, built modules, staged
  source, and the script's `framework.conf` entries; leaves signing keys and
  packages in place. Works whether or not VMware Workstation itself is
  still installed.
- `version` command (also `--version`/`-V`): prints the script version.
- Distro support: Debian/Ubuntu, Fedora/RHEL-family (with automatic EPEL
  enablement), openSUSE, Arch, Gentoo, and Void; missing packages
  (`dkms`, `mokutil`, `openssl`, and `shim-signed` where applicable) are
  installed automatically, including a package-manager probe on
  unrecognized distros.
- Secure Boot signing via DKMS-native MOK directives: reuses an existing
  signing config from `/etc/dkms/framework.conf`, Gentoo's
  `MODULES_SIGN_KEY`/`MODULES_SIGN_CERT` in `make.conf`, or
  Debian/Ubuntu's `shim-signed` key at `/var/lib/shim-signed/mok` before
  falling back to DKMS's own default key location; enrollment compared by
  SHA1 fingerprint.
- Fail-closed refusals for `sbctl`-managed Secure Boot (exit `3`) and
  immutable/atomic roots or NixOS (exit `4`).
- Verbose step-by-step output for detection, actions, and errors, with an
  ERR trap reporting the failing command and line on unexpected failures.
- Accepts both VMware version formats: `17.6.5 build-24583293` and the
  newer prefix-less `26.0.0 25388281`.
