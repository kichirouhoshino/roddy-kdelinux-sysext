#!/usr/bin/env bash
set -euo pipefail

# setup-resolved.sh
# Enables systemd-resolved, configures the symlink for /etc/resolv.conf,
# and integrates it with NetworkManager.

echo "Setting up systemd-resolved..."

# Ensure the script is run on the host
if [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then
  echo "Error: This script must be run on the host system, not inside a container/distrobox." >&2
  exit 1
fi

setup_resolved() {
  echo "1. Configuring systemd-resolved service..."
  systemctl enable --now systemd-resolved.service

  echo "2. Setting up NetworkManager integration..."
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/10-dns-resolved.conf <<NM_EOF
[main]
dns=systemd-resolved
NM_EOF

  echo "3. Creating /etc/resolv.conf symlink..."
  # Backup existing resolv.conf if it's not already a symlink to systemd-resolved
  if [ -e /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    echo "Backing up existing /etc/resolv.conf to /etc/resolv.conf.backup..."
    mv /etc/resolv.conf /etc/resolv.conf.backup
  elif [ -L /etc/resolv.conf ] && [ "$(readlink /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]; then
    echo "Backing up existing resolv.conf symlink to /etc/resolv.conf.backup..."
    mv /etc/resolv.conf /etc/resolv.conf.backup
  else
    rm -f /etc/resolv.conf
  fi

  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  echo "Symlinked /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf"

  echo "4. Restarting services..."
  systemctl restart NetworkManager
  systemctl restart systemd-resolved.service

  echo "Verification status:"
  resolvectl status | head -n 20
  echo "All done! systemd-resolved has been successfully configured and activated."
}

if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Requesting sudo to perform setup actions..."
    sudo bash -c "$(declare -f setup_resolved); setup_resolved"
  else
    echo "Error: This script requires root privileges. Please run as root or with sudo." >&2
    exit 1
  fi
else
  setup_resolved
fi
