#!/usr/bin/env bash
set -euo pipefail

# install-epson-l120.sh
# Extracts a local EPSON binary RPM, prepares a sysext rootfs,
# and installs it as a folder-based systemd-sysext extension
# under /var/lib/extensions/.
#
# WARNING: Run this on the host (not inside a distrobox). The install step
# will require root privileges (the script attempts to use sudo if needed).

NAME="epson-inkjet-printer-201310w"

uninstall_cmd() {
  echo "Removing system extension files..."
  rm -rf "/var/lib/extensions/${NAME}"

  if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting systemd-sysext..."
    systemctl restart systemd-sysext.service || true
    systemctl daemon-reload || true
  fi
  echo "Uninstallation of Epson L120 system extension completed!"
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "Requesting sudo to perform uninstallation on the host..."
      sudo env NAME="$NAME" bash -c "$(declare -f uninstall_cmd); uninstall_cmd"
    else
      echo "Error: Uninstallation requires root privileges. Please run as root or with sudo." >&2
      exit 1
    fi
  else
    uninstall_cmd
  fi
  exit 0
fi

RPM_URL="https://download-center.epson.com/f/module/4cc47666-8c06-4d18-a12f-9d1e0cc14490/epson-inkjet-printer-201310w-1.0.1-1.x86_64.rpm"
RPM_FILE=""

if [ $# -eq 1 ]; then
  if [ -f "$1" ]; then
    RPM_FILE="$(realpath "$1")"
  else
    echo "Error: Specified file '$1' does not exist." >&2
    exit 1
  fi
elif [ $# -eq 0 ]; then
  echo "No local RPM file specified. Will download automatically..."
else
  echo "Usage: $0 [/path/to/epson-inkjet-printer-201310w-1.0.1-1.x86_64.rpm | --uninstall]" >&2
  exit 1
fi

echo "This script will: (1) extract the binary RPM, (2) create a folder-based sysext, (3) install it on the host."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Working in $TMP"
cd "$TMP"

if [ -n "$RPM_FILE" ]; then
  echo "Using local RPM file: $RPM_FILE"
  cp "$RPM_FILE" bin.rpm
else
  echo "Downloading RPM from: $RPM_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -L -o bin.rpm "$RPM_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O bin.rpm "$RPM_URL"
  else
    echo "Missing required tool: curl or wget. Install one and retry." >&2
    exit 1
  fi
fi

echo "Extracting binary RPM using bsdtar..."
if ! command -v bsdtar >/dev/null 2>&1; then
  echo "Missing required tool: bsdtar. Install it and retry." >&2
  exit 1
fi

bsdtar -xf bin.rpm

ROOTFS="$TMP/rootfs"
mkdir -p "$ROOTFS"

# Move extracted file structure into ROOTFS
if [ -d "opt" ]; then
  mkdir -p "$ROOTFS/opt"
  cp -a opt/* "$ROOTFS/opt/"
fi

if [ -d "usr" ]; then
  mkdir -p "$ROOTFS/usr"
  cp -a usr/* "$ROOTFS/usr/"
fi

# Fix lib64 symlink overlay issue
if [ -d "$ROOTFS/usr/lib64" ]; then
  mkdir -p "$ROOTFS/usr/lib"
  cp -a "$ROOTFS/usr/lib64/"* "$ROOTFS/usr/lib/" 2>/dev/null || true
  rm -rf "$ROOTFS/usr/lib64"
fi

# Ensure CUPS PPDs are registered in a path CUPS expects
if [ -d "$ROOTFS/opt/epson-inkjet-printer-201310w/ppds" ]; then
  mkdir -p "$ROOTFS/usr/share/cups/model"
  ln -sf /opt/epson-inkjet-printer-201310w/ppds "$ROOTFS/usr/share/cups/model/epson-inkjet-printer-201310w"
fi

# Ensure CUPS filter is placed where CUPS looks for filters
if [ -f "$ROOTFS/opt/epson-inkjet-printer-201310w/cups/lib/filter/epson_inkjet_printer_filter" ]; then
  mkdir -p -m 0755 "$ROOTFS/usr/lib/cups/filter"
  ln -sf /opt/epson-inkjet-printer-201310w/cups/lib/filter/epson_inkjet_printer_filter "$ROOTFS/usr/lib/cups/filter/epson_inkjet_printer_filter"
fi

# Force correct permissions for all files in ROOTFS to satisfy CUPS security requirements
# (CUPS rejects filters if any part of their path is group-writable/world-writable)
chmod -R u=rwX,go=rX "$ROOTFS"
if [ -f "$ROOTFS/opt/epson-inkjet-printer-201310w/cups/lib/filter/epson_inkjet_printer_filter" ]; then
  chmod 0755 "$ROOTFS/opt/epson-inkjet-printer-201310w/cups/lib/filter/epson_inkjet_printer_filter"
fi

if [ -z "$(ls -A "$ROOTFS")" ]; then
  echo "No files copied into rootfs; aborting." >&2
  exit 1
fi

# Create extension-release metadata to allow merging on different hosts
mkdir -p "$ROOTFS/usr/lib/extension-release.d"
cat > "$ROOTFS/usr/lib/extension-release.d/extension-release.${NAME}" <<INNER_EOF
ID=_any
NAME=${NAME}
VERSION_ID=1.0.1
INNER_EOF

# Install to host
install_cmd() {
  local src="$SRC_PATH"
  local dest_dir="/var/lib/extensions/${NAME}"
  
  echo "Installing folder-based system extension to host under $dest_dir"
  
  # Clean old directories if they exist
  rm -rf "$dest_dir"
  mkdir -p "/var/lib/extensions"
  
  # Copy staged rootfs as the extension folder
  cp -a "$src" "$dest_dir"
  
  if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting systemd-sysext.service to merge the extension..."
    systemctl restart systemd-sysext.service || echo "Failed to restart systemd-sysext.service; check logs." >&2
    systemctl daemon-reload || true
  else
    echo "systemctl not found: please restart systemd-sysext.service manually." >&2
  fi
  
  echo "Folder-based extension installed successfully! Run 'systemd-sysext list' to verify."
}

SRC_PATH="$ROOTFS"
export SRC_PATH NAME

if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Requesting sudo to deploy the folder-based extension to /var/lib/extensions..."
    sudo env SRC_PATH="$SRC_PATH" NAME="$NAME" bash -c "$(declare -f install_cmd); install_cmd"
  else
    echo "Not running as root and sudo not available. To install the extension, run as root:" >&2
    echo "  cp -a $SRC_PATH /var/lib/extensions/${NAME} && systemctl restart systemd-sysext.service" >&2
    exit 1
  fi
else
  install_cmd
fi

echo "All done. You can inspect installed extensions with: systemd-sysext list"
