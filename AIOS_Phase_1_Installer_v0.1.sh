#!/usr/bin/env bash
#
# AIOS Phase 1 Installer — v0.1 Reproducible Base
# Target: NixOS 26.05 x86_64 VMware development VM
#
# Phase 1 installs only the reproducible AIOS foundation:
# - /srv/aios local-first directory structure
# - local NixOS flake source tree
# - pinned flake.lock
# - declarative swapfile (8 GiB by default)
# - NixOS firewall
# - VMware guest integration
# - base CLI tools including Git
# - test rebuild, switch rebuild, smoke tests
# - local Git repository + aios-v0.1-base tag
#
# It deliberately does NOT install Forgejo, Podman workers, PostgreSQL,
# AI models, Open WebUI, the Supervisor, or creative/engineering services.
#
# Usage:
#   chmod +x AIOS_Phase_1_Installer_v0.1.sh
#   sudo ./AIOS_Phase_1_Installer_v0.1.sh
#
# Optional:
#   AIOS_SWAP_GB=16 sudo -E ./AIOS_Phase_1_Installer_v0.1.sh
#   sudo ./AIOS_Phase_1_Installer_v0.1.sh --yes
#   sudo ./AIOS_Phase_1_Installer_v0.1.sh --force
#
set -Eeuo pipefail
IFS=$'\n\t'

AIOS_VERSION="0.1"
AIOS_ROOT="/srv/aios"
SYSTEM_REPO="${AIOS_ROOT}/source/aios-system"
FLAKE_TARGET="${SYSTEM_REPO}#dev-vm"
SWAP_GB="${AIOS_SWAP_GB:-8}"
ASSUME_YES=0
FORCE=0
STAMP="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;36m[AIOS]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local line="$1"
  printf '\n\033[1;31m[AIOS] Phase 1 stopped at line %s.\033[0m\n' "$line" >&2
  printf 'The original /etc/nixos configuration has not been deleted.\n' >&2
  printf 'If a NixOS test/switch failed, reboot and select the previous NixOS generation if needed.\n' >&2
}
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<'EOF'
AIOS Phase 1 Installer — v0.1 Reproducible Base

Options:
  --yes        Do not ask for the initial confirmation.
  --force      Archive an existing AIOS system repo and recreate it.
  -h, --help   Show this help.

Environment:
  AIOS_SWAP_GB=<n>   Swapfile size in GiB. Default: 8.

Recommended first:
  Take a VMware snapshot named: AIOS-BASE-CLEAN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo."

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  AIOS_USER="$SUDO_USER"
else
  AIOS_USER="$(logname 2>/dev/null || true)"
fi
[[ -n "${AIOS_USER:-}" && "$AIOS_USER" != "root" ]] || \
  die "Could not determine the normal user. Run this with sudo from your desktop account."

id "$AIOS_USER" >/dev/null 2>&1 || die "User '$AIOS_USER' does not exist."
AIOS_GROUP="$(id -gn "$AIOS_USER")"

[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "nixos" ]] || die "This Phase 1 installer is for NixOS only."
[[ "$(uname -m)" == "x86_64" ]] || die "Phase 1 currently targets x86_64 NixOS."
[[ -f /etc/nixos/configuration.nix ]] || die "/etc/nixos/configuration.nix was not found."
[[ -f /etc/nixos/hardware-configuration.nix ]] || die "/etc/nixos/hardware-configuration.nix was not found."
command -v nix >/dev/null 2>&1 || die "The nix command is missing."
command -v nixos-rebuild >/dev/null 2>&1 || die "nixos-rebuild is missing."

[[ "$SWAP_GB" =~ ^[0-9]+$ ]] || die "AIOS_SWAP_GB must be a whole number."
(( SWAP_GB >= 2 && SWAP_GB <= 64 )) || die "Choose a swap size between 2 and 64 GiB."
SWAP_MIB=$((SWAP_GB * 1024))

cat <<EOF

============================================================
 AIOS Phase 1 — Reproducible Base
============================================================
 Host OS:       ${PRETTY_NAME:-NixOS}
 User:          ${AIOS_USER}
 Architecture:  $(uname -m)
 AIOS root:     ${AIOS_ROOT}
 System repo:   ${SYSTEM_REPO}
 Swapfile:      ${SWAP_GB} GiB
 Flake target:  ${FLAKE_TARGET}
============================================================

This will create the local AIOS source tree and perform:
  1. nix flake lock
  2. nixos-rebuild TEST
  3. nixos-rebuild SWITCH

It will NOT erase your existing /etc/nixos configuration.
A timestamped copy of /etc/nixos will be saved first.

EOF

if (( ASSUME_YES == 0 )); then
  read -r -p "Have you taken a VMware snapshot (recommended: AIOS-BASE-CLEAN)? Continue? [y/N] " answer
  case "${answer:-}" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled. No changes made."; exit 0 ;;
  esac
fi

log "Creating local-first AIOS storage layout..."
install -d -m 0755 -o root -g root "$AIOS_ROOT"

for d in source vendor models projects knowledge forgejo backups; do
  install -d -m 2775 -o "$AIOS_USER" -g "$AIOS_GROUP" "${AIOS_ROOT}/${d}"
done

install -d -m 0755 -o root -g root /var/lib/aios

BACKUP_DIR="${AIOS_ROOT}/backups/etc-nixos-before-v${AIOS_VERSION}-${STAMP}"
log "Backing up /etc/nixos to ${BACKUP_DIR} ..."
install -d -m 0700 -o root -g root "$BACKUP_DIR"
cp -a /etc/nixos/. "$BACKUP_DIR/"
ok "Original NixOS configuration backed up."

if [[ -e "$SYSTEM_REPO" ]]; then
  if (( FORCE == 0 )); then
    die "${SYSTEM_REPO} already exists. Re-run with --force only if you intend to archive and recreate it."
  fi
  ARCHIVE="${AIOS_ROOT}/backups/aios-system-before-reinstall-${STAMP}"
  warn "Archiving existing AIOS system repo to ${ARCHIVE}"
  mv "$SYSTEM_REPO" "$ARCHIVE"
fi

log "Building the AIOS v0.1 source tree..."
install -d -m 2775 -o "$AIOS_USER" -g "$AIOS_GROUP" \
  "$SYSTEM_REPO" \
  "$SYSTEM_REPO/hosts/dev-vm/original" \
  "$SYSTEM_REPO/modules" \
  "$SYSTEM_REPO/scripts" \
  "$SYSTEM_REPO/docs"

# Keep the exact installer-created NixOS configuration so the existing
# user, bootloader, locale, LXQt desktop and hardware setup are preserved.
cp -a /etc/nixos/. "$SYSTEM_REPO/hosts/dev-vm/original/"

cat > "$SYSTEM_REPO/flake.nix" <<'EOF'
{
  description = "AIOS v0.1 - local-first NixOS development system";

  inputs = {
    # Bootstrap dependency only: pinned into flake.lock.
    # AIOS-owned source remains local; later releases vendor critical inputs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.dev-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/dev-vm/default.nix ];
    };
  };
}
EOF

cat > "$SYSTEM_REPO/hosts/dev-vm/default.nix" <<'EOF'
{ ... }:
{
  imports = [
    ./original/configuration.nix
    ../../modules/base.nix
    ../../modules/storage.nix
    ../../modules/vmware.nix
  ];
}
EOF

cat > "$SYSTEM_REPO/modules/base.nix" <<EOF
{ pkgs, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Enabled from the first AIOS generation. Phase 1 opens no new ports.
  networking.firewall.enable = true;

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    jq
    rsync
    vim
    htop
  ];

  # Persistent AIOS layout, recreated declaratively.
  systemd.tmpfiles.rules = [
    "d /srv/aios 0755 root root - -"
    "d /srv/aios/source 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /srv/aios/vendor 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /srv/aios/models 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /srv/aios/projects 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /srv/aios/knowledge 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /srv/aios/forgejo 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /srv/aios/backups 2775 ${AIOS_USER} ${AIOS_GROUP} - -"
    "d /var/lib/aios 0755 root root - -"
  ];
}
EOF

cat > "$SYSTEM_REPO/modules/storage.nix" <<EOF
{ ... }:
{
  # Declarative swapfile for the VMware development VM.
  swapDevices = [
    {
      device = "/swapfile";
      size = ${SWAP_MIB};
    }
  ];
}
EOF

cat > "$SYSTEM_REPO/modules/vmware.nix" <<'EOF'
{ ... }:
{
  virtualisation.vmware.guest.enable = true;
  services.xserver.videoDrivers = [ "vmware" ];
}
EOF

cat > "$SYSTEM_REPO/.gitignore" <<'EOF'
result
result-*
.direnv/
*.qcow2
*.vmdk
*.iso
*.img
.DS_Store

# Never commit plaintext credentials or secrets.
secrets/
*.key
*.pem
.env
.env.*
EOF

cat > "$SYSTEM_REPO/README.md" <<EOF
# AIOS System

Local source of truth for the AIOS NixOS host.

## Current milestone

**AIOS v0.1 — Reproducible Base**

- existing NixOS + LXQt desktop preserved
- local flake and lockfile
- ${SWAP_GB} GiB declarative swapfile
- firewall enabled with no new inbound ports
- VMware guest integration
- /srv/aios persistent layout
- local Git history

## Rebuild

\`\`\`bash
sudo nixos-rebuild test --flake /srv/aios/source/aios-system#dev-vm
sudo nixos-rebuild switch --flake /srv/aios/source/aios-system#dev-vm
\`\`\`

AIOS-owned source is local. The v0.1 bootstrap may download the pinned nixpkgs
input from upstream. A later release profile mirrors critical upstream
dependencies into /srv/aios/vendor.

Never place plaintext credentials or secrets in this repository or flake.
EOF

cat > "$SYSTEM_REPO/docs/PHASE-1.md" <<EOF
# Phase 1 / AIOS v0.1

Definition of done:

- Installed NixOS VM still boots into its existing desktop.
- /srv/aios local data structure exists.
- This local flake can rebuild the machine.
- ${SWAP_GB} GiB /swapfile is active.
- NixOS firewall is enabled.
- VMware guest integration is enabled.
- Local Git repository is committed and tagged \`aios-v0.1-base\`.
- A previous NixOS generation remains available for rollback.

Not included yet:

- Podman workers
- Forgejo service
- PostgreSQL/pgvector
- model gateway or AI models
- Open WebUI
- AIOS Supervisor
EOF

cat > "$SYSTEM_REPO/scripts/rebuild.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
sudo nixos-rebuild test --flake /srv/aios/source/aios-system#dev-vm
sudo nixos-rebuild switch --flake /srv/aios/source/aios-system#dev-vm
EOF

cat > "$SYSTEM_REPO/scripts/smoke-test.sh" <<'EOF'
#!/usr/bin/env bash
set -u

PASS=0
FAIL=0
pass() { printf '\033[1;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '\033[1;31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
check_dir() { [[ -d "$1" ]] && pass "Directory exists: $1" || fail "Missing directory: $1"; }

echo "AIOS v0.1 smoke test"
echo "--------------------"

for d in \
  /srv/aios/source \
  /srv/aios/vendor \
  /srv/aios/models \
  /srv/aios/projects \
  /srv/aios/knowledge \
  /srv/aios/forgejo \
  /srv/aios/backups; do
  check_dir "$d"
done

if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
  pass "/swapfile is active"
else
  fail "/swapfile is not active"
fi

if systemctl is-active --quiet vmware-tools.service 2>/dev/null || \
   systemctl is-active --quiet vmtoolsd.service 2>/dev/null; then
  pass "VMware guest tools service is active"
else
  fail "VMware guest tools service was not detected as active"
fi

if systemctl is-active --quiet firewall.service 2>/dev/null; then
  pass "NixOS firewall service is active"
else
  fail "NixOS firewall service was not detected as active"
fi

if command -v git >/dev/null 2>&1; then
  pass "Git is installed"
else
  fail "Git is not installed"
fi

if nix --extra-experimental-features 'nix-command flakes' \
     flake metadata /srv/aios/source/aios-system >/dev/null 2>&1; then
  pass "Local AIOS flake evaluates"
else
  fail "Local AIOS flake metadata check failed"
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
EOF

chmod +x "$SYSTEM_REPO/scripts/rebuild.sh" "$SYSTEM_REPO/scripts/smoke-test.sh"
chown -R "$AIOS_USER:$AIOS_GROUP" "$SYSTEM_REPO"

log "Generating the pinned flake.lock (internet is required for this bootstrap step)..."
(
  cd "$SYSTEM_REPO"
  sudo -u "$AIOS_USER" \
    nix --extra-experimental-features 'nix-command flakes' flake lock
)
[[ -f "$SYSTEM_REPO/flake.lock" ]] || die "flake.lock was not created."
ok "flake.lock created."

log "Evaluating the flake before changing the running system..."
(
  cd "$SYSTEM_REPO"
  sudo -u "$AIOS_USER" \
    nix --extra-experimental-features 'nix-command flakes' flake metadata >/dev/null
)
ok "Flake evaluation succeeded."

log "Running a safe NixOS TEST activation first..."
NIX_CONFIG="experimental-features = nix-command flakes" nixos-rebuild test --flake "$FLAKE_TARGET"
ok "Temporary test activation succeeded."

log "Running the persistent NixOS SWITCH activation..."
NIX_CONFIG="experimental-features = nix-command flakes" nixos-rebuild switch --flake "$FLAKE_TARGET"
ok "AIOS v0.1 NixOS generation activated."

GIT_BIN="/run/current-system/sw/bin/git"
[[ -x "$GIT_BIN" ]] || GIT_BIN="$(command -v git || true)"
[[ -n "$GIT_BIN" ]] || die "Git should have been installed but was not found."

log "Creating the local Git repository..."
sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" init -b main

if ! sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" config --get user.name >/dev/null 2>&1; then
  sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" config user.name "${AIOS_USER} (AIOS Local)"
fi
if ! sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" config --get user.email >/dev/null 2>&1; then
  sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" config user.email "${AIOS_USER}@aios.local"
fi

sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" add -A
sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" commit \
  -m "AIOS v0.1: reproducible NixOS base"
sudo -u "$AIOS_USER" "$GIT_BIN" -C "$SYSTEM_REPO" tag -a aios-v0.1-base \
  -m "AIOS v0.1 reproducible base"
ok "Local Git baseline committed and tagged aios-v0.1-base."

log "Running Phase 1 smoke tests..."
if "$SYSTEM_REPO/scripts/smoke-test.sh"; then
  SMOKE_STATUS="PASS"
  ok "All Phase 1 smoke tests passed."
else
  SMOKE_STATUS="CHECK WARNINGS"
  warn "The system rebuilt successfully, but one or more smoke checks need review."
fi

echo
echo "============================================================"
echo " AIOS PHASE 1 COMPLETE"
echo "============================================================"
echo " Source:       $SYSTEM_REPO"
echo " Flake:        $FLAKE_TARGET"
echo " Git tag:      aios-v0.1-base"
echo " Swap:         ${SWAP_GB} GiB declarative /swapfile"
echo " Smoke tests:  $SMOKE_STATUS"
echo " Backup:       $BACKUP_DIR"
echo
echo "Next manual step:"
echo "  Take a VMware snapshot named: AIOS-v0.1-REPRODUCIBLE-BASE"
echo
echo "Useful commands:"
echo "  cd $SYSTEM_REPO"
echo "  git log --oneline --decorate -5"
echo "  sudo ./scripts/rebuild.sh"
echo "  ./scripts/smoke-test.sh"
echo "  swapon --show"
echo "  sudo nixos-rebuild list-generations"
echo
echo "Phase 1 intentionally stops here. Podman/Forgejo/models are next."
echo "============================================================"
