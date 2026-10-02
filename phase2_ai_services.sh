#!/usr/bin/env bash
set -euo pipefail

echo "=== AIOS Phase 2: Deploying Model Gateway & Bootstrap UI ==="

CONFIG_FILE="/srv/aios/source/aios-system/hosts/dev-vm/configuration.nix"

# We will append the OCI container definitions to the existing configuration.nix
# In a mature setup, these would be split into separate NixOS modules in /modules/

cat << 'EOF' >> $CONFIG_FILE

  # --- AI Services via OCI Containers (Section 10, 12) ---
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers = {
    
    # Ollama - Local Model Runtime (Section 12)
    ollama = {
      image = "ollama/ollama:latest";
      volumes = [ "/srv/aios/models/ollama:/root/.ollama" ];
      ports = [ "127.0.0.1:11434:11434" ];
      environment = { OLLAMA_HOST = "0.0.0.0"; };
      extraOptions = [ "--network=aios-bridge" ];
    };

    # Open WebUI - Bootstrap Console (Section 6, ADR-007)
    openwebui = {
      image = "ghcr.io/open-webui/open-webui:main";
      volumes = [ "/srv/aios/models/openwebui:/app/backend/data" ];
      ports = [ "127.0.0.1:8080:8080" ];
      environment = {
        OLLAMA_BASE_URL = "http://ollama:11434";
        WEBUI_AUTH = "false"; # Disabled for local-only bootstrap
      };
      dependsOn = [ "ollama" ];
      extraOptions = [ "--network=aios-bridge" ];
    };
  };

  # Create the private bridge network for AI services
  systemd.services.podman-aios-network = {
    description = "Create AIOS Podman Bridge Network";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.podman}/bin/podman network create aios-bridge || true";
      ExecStop = "${pkgs.podman}/bin/podman network rm aios-bridge || true";
    };
  };
EOF

echo "Applying AI Services configuration..."
cd /srv/aios/source/aios-system
sudo nixos-rebuild switch --flake .#dev-vm

# Pull the initial small model mentioned in Section 14 (Qwen3.5-4B or similar compact model)
echo "Downloading baseline compact model (Qwen 2.5 7B as a proxy for Qwen3.5-4B until exact weights are mirrored)..."
podman exec ollama ollama pull qwen2.5:7b

# Commit the changes
cd /srv/aios/source/aios-system
git add .
git commit -m "feat: Add Ollama and Open WebUI via Podman OCI containers"

echo "=== Phase 2 Complete ==="
echo "Open WebUI is now available at: http://localhost:8080"
echo "Forgejo is available at: http://localhost:3000"
echo "Next Step: Take a VMware Snapshot named 'AIOS-v0.2-Core-Ready'."