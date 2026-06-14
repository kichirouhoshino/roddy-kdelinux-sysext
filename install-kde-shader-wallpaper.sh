#!/usr/bin/env bash
set -euo pipefail

# install-kde-shader-wallpaper.sh
# Clones, compiles, and packages the kde-shader-wallpaper plugin
# as a folder-based systemd-sysext system extension under /var/lib/extensions/.
#
# WARNING: Run this on the host (not inside a distrobox) since it compiles
# against host graphics and PipeWire libraries, and requires root permissions
# to install under /var/lib/extensions.

NAME="kde-shader-wallpaper"

uninstall_cmd() {
  echo "Removing system extension files..."
  rm -rf "/var/lib/extensions/${NAME}"

  if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting systemd-sysext..."
    systemctl restart systemd-sysext.service || true
    systemctl daemon-reload || true
  fi
  echo "Uninstallation of KDE Shader Wallpaper system extension completed!"
  echo "Please run: systemctl --user restart plasma-plasmashell.service"
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

REPO_URL="https://github.com/y4my4my4m/kde-shader-wallpaper"

echo "This script will: (1) clone/download the source, (2) compile it natively on the host, (3) create and install a folder-based sysext."

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
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -Wno-dev ..

echo "Compiling the plugin..."
make -j$(nproc)

ROOTFS="$TMP/rootfs"
mkdir -p "$ROOTFS"

echo "Installing files to staging directory..."
make DESTDIR="$ROOTFS" install

# Create extension-release metadata to allow merging on different hosts
mkdir -p "$ROOTFS/usr/lib/extension-release.d"
cat > "$ROOTFS/usr/lib/extension-release.d/extension-release.${NAME}" <<INNER_EOF
ID=_any
NAME=${NAME}
INNER_EOF

# Deployment function that requires root privileges
install_cmd() {
  local src="$SRC_PATH"
  local dest_dir="/var/lib/extensions/kde-shader-wallpaper"
  
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
    echo "  cp -a $SRC_PATH /var/lib/extensions/kde-shader-wallpaper && systemctl restart systemd-sysext.service" >&2
    exit 1
  fi
else
  install_cmd
fi

echo "All done. You can inspect installed extensions with: systemd-sysext list"
