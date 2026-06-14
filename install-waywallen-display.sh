#!/usr/bin/env bash
set -euo pipefail

# install-waywallen-display.sh
# Clones, compiles, and packages the waywallen-display library, QML plugin,
# and the KDE wallpaper extension as a folder-based systemd-sysext system extension
# under /var/lib/extensions/.
#
# WARNING: Run this on the host (not inside a distrobox) since it compiles
# against host graphics and Qt6/KF6 libraries, and requires root permissions
# to install under /var/lib/extensions.

EXTENSION_NAME="waywallen-display"

uninstall_cmd() {
  echo "Removing system extension files..."
  rm -rf "/var/lib/extensions/${EXTENSION_NAME}"

  if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting systemd-sysext..."
    systemctl restart systemd-sysext.service || true
    systemctl daemon-reload || true
  fi
  echo "Uninstallation of Waywallen Display system extension completed!"
  echo "Please run: systemctl --user restart plasma-plasmashell.service"
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "Requesting sudo to perform uninstallation on the host..."
      sudo env EXTENSION_NAME="$EXTENSION_NAME" bash -c "$(declare -f uninstall_cmd); uninstall_cmd"
    else
      echo "Error: Uninstallation requires root privileges. Please run as root or with sudo." >&2
      exit 1
    fi
  else
    uninstall_cmd
  fi
  exit 0
fi

REPO_URL="https://github.com/waywallen/waywallen-display"
NAME="waywallen-display"

echo "This script will: (1) clone the waywallen-display source, (2) compile it and the QML plugin natively on the host, (3) stage the files along with the KDE wallpaper package, (4) deploy it as a folder-based sysext."

# Create temporary directory for cloning and building
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Working in $TMP"
cd "$TMP"

echo "Checking build dependencies..."
missing=()
for tool in cmake make pkg-config git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if [ ${#missing[@]} -ne 0 ]; then
  echo "Missing required build tools: ${missing[*]}. Please install them on your host and try again." >&2
  exit 1
fi

echo "Cloning source repository..."
git clone --depth 1 "$REPO_URL" source
cd source

echo "Configuring build with CMake..."
mkdir build
cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DWAYWALLEN_DISPLAY_PLUGIN_QML=ON -Wno-dev ..

echo "Compiling the library and QML plugin..."
make -j$(nproc)

ROOTFS="$TMP/rootfs"
mkdir -p "$ROOTFS"

echo "Installing files to staging directory..."
make DESTDIR="$ROOTFS" install

echo "Staging the KDE wallpaper package..."
mkdir -p "$ROOTFS/usr/share/plasma/wallpapers/org.waywallen.kde"
cp -a ../extensions/kde/package/* "$ROOTFS/usr/share/plasma/wallpapers/org.waywallen.kde/"

# Create extension-release metadata to allow merging on different hosts
mkdir -p "$ROOTFS/usr/lib/extension-release.d"
cat > "$ROOTFS/usr/lib/extension-release.d/extension-release.${EXTENSION_NAME}" <<INNER_EOF
ID=_any
NAME=${EXTENSION_NAME}
INNER_EOF

# Deployment function that requires root privileges
install_cmd() {
  local src="$SRC_PATH"
  local dest_dir="/var/lib/extensions/waywallen-display"
  
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
  echo "Then run: systemctl --user restart plasma-plasmashell.service"
}

SRC_PATH="$ROOTFS"
export SRC_PATH NAME

if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Requesting sudo to deploy the folder-based extension to /var/lib/extensions..."
    sudo env SRC_PATH="$SRC_PATH" NAME="$NAME" bash -c "$(declare -f install_cmd); install_cmd"
  else
    echo "Not running as root and sudo not available. To install the extension, run as root:" >&2
    echo "  cp -a $SRC_PATH /var/lib/extensions/waywallen-display && systemctl restart systemd-sysext.service" >&2
    exit 1
  fi
else
  install_cmd
fi

echo "All done. You can inspect installed extensions with: systemd-sysext list"
