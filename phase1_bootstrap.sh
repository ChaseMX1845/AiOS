#!/usr/bin/env bash
set -euo pipefail

echo "=== AIOS Phase 1: Bootstrapping Local Source of Truth & Core OS ==="

# 1. Create the AIOS Directory Structure (Section 4)
echo "Creating /srv/aios directory layout..."
sudo mkdir -p /srv/aios/{source/aios-system/{hosts/dev-vm,modules,containers,schemas,tests},vendor,models,projects,knowledge,backups}
sudo chown -R $USER:users /srv/aios

# 2. Migrate existing NixOS config to the new Flake structure
echo "Migrating base configuration to local repo..."
if [ -f /etc/nixos/configuration.nix ]; then
    sudo cp /etc/nixos/configuration.nix /srv/aios/source/aios-system/hosts/dev-vm/
    sudo cp /etc/nixos/hardware-configuration.nix /srv/aios/source/aios-system/hosts/dev-vm/ 2>/dev/null || true
fi

# 3. Generate the AIOS Flake.nix
echo "Generating flake.nix..."
cat << 'EOF' > /srv/aios/source/aios-system/flake.nix
{
  description = "AIOS Master System - Dev VM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.dev-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ 
        ./hosts/dev-vm/configuration.nix 
      ];
    };
  };
}
EOF

# 4. Generate the Declarative AIOS Configuration (v0.1 & v0.2 Scope)
echo "Generating declarative configuration.nix..."
cat << 'EOF' > /srv/aios/source/aios-system/hosts/dev-vm/configuration.nix
{ config, pkgs, lib, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # --- Nix & Flakes Configuration ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };

  # --- Boot & System ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  system.stateVersion = "24.05"; # Did you read the comment?

  # --- Swapfile (Section 26, Step 6) ---
  swapDevices = [ { device = "/swapfile"; size = 16384; } ]; # 16GB Swapfile

  # --- Desktop Environment (LXQt) ---
  services.xserver = {
    enable = true;
    desktopManager.lxqt.enable = true;
    displayManager.lightdm.enable = true;
  };

  # --- Networking & Firewall ---
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # --- Core Services (Section 26, Steps 8-9) ---
  
  # Rootless Podman (ADR-003)
  virtualisation.podman = {
    enable = true;
    dockerCompat = true; # Allows using 'docker' command as alias
    defaultNetwork.settings = { dns_enabled = true; };
  };

  # PostgreSQL + pgvector (ADR-008)
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    ensureDatabases = [ "aios_supervisor" "forgejo" ];
    ensureUsers = [
      { name = "aios"; ensureDBOwnership = true; }
      { name = "forgejo"; ensureDBOwnership = true; }
    ];
    extensions = ps: with ps; [ pgvector ];
  };

  # Local Forge (Section 4, 19)
  services.forgejo = {
    enable = true;
    database.type = "postgres";
    database.host = "/run/postgresql";
    database.name = "forgejo";
    database.user = "forgejo";
    settings.server.DOMAIN = "localhost";
    settings.server.ROOT_URL = "http://localhost:3000/";
  };

  # Reverse Proxy (Section 10)
  services.caddy.enable = true;

  # --- System Packages ---
  environment.systemPackages = with pkgs; [
    git vim htop curl wget jq
    podman-compose
    python311 python311Packages.pip
  ];

  # --- Users ---
  users.users.${builtins.getEnv "USER"} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "podman" "postgres" ]; # Allow rootless podman and db access
  };
}
EOF

# 5. Apply the NixOS Configuration
echo "Applying NixOS configuration (This will download packages and build the OS)..."
cd /srv/aios/source/aios-system
sudo nixos-rebuild switch --flake .#dev-vm

# 6. Initialize Local Git (Section 19)
echo "Initializing local Git repository..."
cd /srv/aios/source/aios-system
git init
git add .
git commit -m "chore: AIOS v0.1 base - reproducible NixOS flake, LXQt, Podman, Postgres, Forgejo"

echo "=== Phase 1 Complete ==="
echo "Next Steps:"
echo "1. Reboot your VM to ensure LXQt and Swapfile are active."
echo "2. Take a VMware Snapshot named 'AIOS-v0.1-BASE-CLEAN'."
echo "3. Run phase2_ai_services.sh to deploy the Model Gateway and Open WebUI."