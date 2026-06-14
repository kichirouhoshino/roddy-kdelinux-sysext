#!/usr/bin/env bash
set -euo pipefail

# create_and_install_warp_sysext.sh
# Extracts a local Cloudflare Warp binary RPM, prepares a sysext rootfs,
# and installs it as a folder-based systemd-sysext extension
# under /var/lib/extensions/.

NAME="cloudflare-warp"

uninstall_cmd() {
  echo "Stopping and disabling services..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop warp-svc.service 2>/dev/null || true
    systemctl disable warp-svc.service 2>/dev/null || true
    systemctl stop warp-sysext-enable.service 2>/dev/null || true
    systemctl disable warp-sysext-enable.service 2>/dev/null || true
  fi

  echo "Removing host-side helper service..."
  rm -f /etc/systemd/system/warp-sysext-enable.service

  echo "Removing system extension files..."
  rm -rf "/var/lib/extensions/${NAME}"

  if [ -e /etc/resolv.conf.backup ]; then
    echo "Restoring backed up /etc/resolv.conf..."
    rm -f /etc/resolv.conf
    mv /etc/resolv.conf.backup /etc/resolv.conf
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting systemd-sysext..."
    systemctl restart systemd-sysext.service || true
    systemctl daemon-reload || true
  fi
  echo "Uninstallation of Cloudflare Warp system extension completed!"
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

RPM_FILE=""
if [ $# -eq 1 ]; then
  if [ -f "$1" ]; then
    RPM_FILE="$(realpath "$1")"
  else
    echo "Error: Specified file '$1' does not exist." >&2
    exit 1
  fi
elif [ $# -eq 0 ]; then
  echo "No local RPM file specified. Will query and download the latest version automatically..."
else
  echo "Usage: $0 [/path/to/cloudflare-warp.x86_64.rpm | --uninstall]" >&2
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
  echo "Fetching latest Cloudflare Warp RPM URL from repository..."
  RPM_URL=$(python3 -c "
import sys, urllib.request, gzip
import xml.etree.ElementTree as ET
repomd_url = 'https://pkg.cloudflareclient.com/rpm/repodata/repomd.xml'
req = urllib.request.Request(repomd_url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req) as r:
        root = ET.fromstring(r.read())
except Exception as e:
    print(f'Error fetching repomd.xml: {e}', file=sys.stderr)
    sys.exit(1)
ns = {'repo': 'http://linux.duke.edu/metadata/repo'}
primary_href = None
for data in root.findall('repo:data', ns):
    if data.get('type') == 'primary':
        loc = data.find('repo:location', ns)
        if loc is not None:
            primary_href = loc.get('href')
            break
if not primary_href:
    print('Failed to find primary metadata href', file=sys.stderr); sys.exit(1)
primary_url = f'https://pkg.cloudflareclient.com/rpm/{primary_href}'
req2 = urllib.request.Request(primary_url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req2) as r:
        root = ET.fromstring(gzip.decompress(r.read()))
except Exception as e:
    print(f'Error fetching primary metadata: {e}', file=sys.stderr)
    sys.exit(1)
ns = {'common': 'http://linux.duke.edu/metadata/common'}
rpm_href = None
for pkg in root.findall('common:package', ns):
    name_el = pkg.find('common:name', ns)
    arch_el = pkg.find('common:arch', ns)
    if name_el is not None and name_el.text == 'cloudflare-warp' and arch_el is not None and arch_el.text == 'x86_64':
        loc = pkg.find('common:location', ns)
        if loc is not None:
            rpm_href = loc.get('href')
            break
if not rpm_href:
    print('Failed to find cloudflare-warp x86_64 package in metadata', file=sys.stderr); sys.exit(1)
print(f'https://pkg.cloudflareclient.com/rpm/{rpm_href}')
")
  echo "Latest RPM URL: $RPM_URL"
  echo "Downloading RPM..."
  curl -L -o bin.rpm "$RPM_URL"
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
# Sysext only cares about /usr and /opt. Anything in /etc or /var must be handled by the daemon
if [ -d "opt" ]; then
  mkdir -p "$ROOTFS/opt"
  cp -a opt/* "$ROOTFS/opt/"
fi

if [ -d "usr" ]; then
  mkdir -p "$ROOTFS/usr"
  cp -a usr/* "$ROOTFS/usr/"
fi

# Move /bin to /usr/bin since sysext requires binaries in /usr
if [ -d "bin" ]; then
  mkdir -p "$ROOTFS/usr/bin"
  cp -a bin/* "$ROOTFS/usr/bin/"
fi

# Move /lib to /usr/lib (e.g., systemd units)
if [ -d "lib" ]; then
  mkdir -p "$ROOTFS/usr/lib"
  cp -a lib/* "$ROOTFS/usr/lib/"
fi

# Copy the systemd service file from opt if present in the RPM structure
SVC_FILE="$ROOTFS/usr/lib/systemd/system/warp-svc.service"
mkdir -p "$ROOTFS/usr/lib/systemd/system"
if [ -f "$ROOTFS/opt/cloudflare-warp/warp-svc.service" ]; then
  cp "$ROOTFS/opt/cloudflare-warp/warp-svc.service" "$SVC_FILE"
fi

# Patch the service file to use the correct binary path in sysext
if [ -f "$SVC_FILE" ]; then
  echo "Patching warp-svc.service to use correct binary paths and dependencies..."
  # Fix binary paths
  sed -i 's|ExecStart=/bin/warp-svc|ExecStart=/usr/bin/warp-svc|g' "$SVC_FILE"
  sed -i 's|ExecStart=/sbin/|ExecStart=/usr/sbin/|g' "$SVC_FILE"
  # Ensure the service waits for systemd-sysext to load the extension
  sed -i '/^After=/s/$/\nAfter=systemd-sysext.service/' "$SVC_FILE"
  sed -i '/^\[Unit\]/a Wants=systemd-sysext.service' "$SVC_FILE"
  echo "Enabling warp-svc.service in the extension..."
  mkdir -p "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants"
  ln -sf ../warp-svc.service "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/warp-svc.service"
fi

# Remove taskbar functionality (avoids heavy GUI dependencies like webkit2gtk)
echo "Removing warp-taskbar components..."
find "$ROOTFS" -name "*warp-taskbar*" -exec rm -rf {} + 2>/dev/null || true
find "$ROOTFS" -type f -name "*taskbar*.desktop" -delete 2>/dev/null || true

if [ -z "$(ls -A "$ROOTFS")" ]; then
  echo "No files copied into rootfs; aborting." >&2
  exit 1
fi

# Create extension-release metadata to allow merging on different hosts
mkdir -p "$ROOTFS/usr/lib/extension-release.d"
cat > "$ROOTFS/usr/lib/extension-release.d/extension-release.${NAME}" <<INNER_EOF
ID=_any
NAME=${NAME}
INNER_EOF

# Install to host
install_cmd() {
  local src="$SRC_PATH"
  local dest_dir="/var/lib/extensions/${NAME}"
  local resolv_src=""
  echo "Installing folder-based system extension to host under $dest_dir"
  mkdir -p -m0755 "/var/lib/extensions"
  rm -rf "$dest_dir"
  cp -a "$src" "$dest_dir"

  if [ ! -e /etc/resolv.conf ]; then
    if [ -e /run/systemd/resolve/stub-resolv.conf ]; then
      resolv_src="/run/systemd/resolve/stub-resolv.conf"
    elif [ -e /run/systemd/resolve/resolv.conf ]; then
      resolv_src="/run/systemd/resolve/resolv.conf"
    fi

    if [ -n "$resolv_src" ]; then
      ln -s "$resolv_src" /etc/resolv.conf
      echo "Created /etc/resolv.conf symlink -> $resolv_src"
    else
      echo "Skipping /etc/resolv.conf symlink: no systemd-resolved target is available." >&2
    fi
  else
    echo "Skipping /etc/resolv.conf symlink: file already exists."
  fi

  # Create a host-side helper service to load and start warp-svc on boot
  echo "Creating host-side helper service to start warp-svc on boot..."
  cat > /etc/systemd/system/warp-sysext-enable.service <<EOF
[Unit]
Description=Enable and start Cloudflare Warp System Extension service
After=systemd-sysext.service
Requires=systemd-sysext.service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl daemon-reload
ExecStartPost=/usr/bin/systemctl restart warp-svc.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  if command -v systemctl >/dev/null 2>&1; then
    echo "Registering and starting services on the host..."
    systemctl restart systemd-sysext.service || echo "Failed to restart systemd-sysext.service; check logs." >&2
    systemctl daemon-reload || true
    systemctl enable warp-sysext-enable.service || true
    systemctl start warp-sysext-enable.service || true
    echo "Installed successfully and enabled to start on boot via warp-sysext-enable.service!"
    echo "Run 'systemd-sysext list' to verify the extension is merged."
  else
    echo "systemctl not found: please restart systemd-sysext.service and warp-sysext-enable.service manually." >&2
  fi
}

SRC_PATH="$ROOTFS"
export SRC_PATH NAME

if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Requesting sudo to install the folder-based extension on the host..."
    sudo env SRC_PATH="$SRC_PATH" NAME="$NAME" bash -c "$(declare -f install_cmd); install_cmd"
  else
    echo "Not running as root and sudo not available. To install the extension, run as root:" >&2
    echo "  cp -a $SRC_PATH /var/lib/extensions/${NAME} && systemctl restart systemd-sysext.service" >&2
    exit 1
  fi
else
  install_cmd
fi
