#!/usr/bin/env bash
set -euo pipefail

# create_and_install_warp_sysext.sh
# Extracts a local Cloudflare Warp binary DEB, prepares a sysext rootfs,
# builds a .raw image (erofs preferred, squashfs fallback) and installs it on
# the host under /var/lib/extensions.d/ and /var/lib/extensions/.

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: $0 /path/to/cloudflare-warp_2026.4.1350.0_amd64.deb" >&2
  exit 1
fi
DEB_FILE="$(realpath "$1")"

NAME="cloudflare-warp"
OUT_RAW="${NAME}.raw"

echo "This script will: (1) extract the binary DEB, (2) create a sysext .raw, (3) install it on the host."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Working in $TMP"
cd "$TMP"

echo "Using local DEB file: $DEB_FILE"
cp "$DEB_FILE" bin.deb

echo "Extracting binary DEB using ar and tar..."
if ! command -v ar >/dev/null 2>&1; then
  echo "Missing required tool: ar (binutils). Install it and retry." >&2
  exit 1
fi

ar x bin.deb >/dev/null
if [ -f data.tar.zst ]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "Missing required tool: zstd. Install it and retry." >&2
    exit 1
  fi
  tar --zstd -xf data.tar.zst
elif [ -f data.tar.xz ]; then
  tar -xf data.tar.xz
elif [ -f data.tar.gz ]; then
  tar -zxf data.tar.gz
else
  echo "Could not find a recognized data.tar archive in the DEB package." >&2
  exit 1
fi

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

# Ensure warp-svc.service starts on boot by baking the enablement symlink into the extension
SVC_FILE="$ROOTFS/usr/lib/systemd/system/warp-svc.service"
if [ -f "$SVC_FILE" ]; then
  echo "Enabling warp-svc.service in the extension..."
  mkdir -p "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants"
  ln -sf ../warp-svc.service "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/warp-svc.service"
fi

# Remove taskbar functionality (avoids heavy GUI dependencies like webkit2gtk)
echo "Removing warp-taskbar components..."
find "$ROOTFS" -name "*warp-taskbar*" -exec rm -rf {} + 2>/dev/null || true

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

echo "Preparing image at $OUT_RAW"

validate_image() {
  local img="$1"
  if [ ! -s "$img" ]; then
    echo "Image $img is empty or missing." >&2
    return 1
  fi
  if command -v file >/dev/null 2>&1; then
    local ftype
    ftype=$(file -b "$img")
    case "$ftype" in
      *"EROFS"*|*"Squashfs"*) return 0 ;;
      *)
        echo "Image $img has unexpected type: $ftype" >&2
        return 1
        ;;
    esac
  fi
  return 0
}

create_erofs() {
  local tmp_img="$OUT_RAW.tmp"
  rm -f "$tmp_img"
  echo "Creating erofs image (preferred)"
  if mkfs.erofs -z lz4 --force-uid=0 --force-gid=0 "$tmp_img" "$ROOTFS" >/dev/null 2>&1; then
    if validate_image "$tmp_img"; then
      mv -f "$tmp_img" "$OUT_RAW"
      echo "erofs image created: $OUT_RAW"
      return 0
    fi
  fi
  rm -f "$tmp_img"
  echo "mkfs.erofs failed or produced invalid image; will try squashfs fallback" >&2
  return 1
}

create_squashfs() {
  local tmp_img="$OUT_RAW.tmp"
  rm -f "$tmp_img"
  echo "Creating squashfs image as fallback"
  if mksquashfs "$ROOTFS" "$tmp_img" -comp gzip -noappend -all-root >/dev/null; then
    if validate_image "$tmp_img"; then
      mv -f "$tmp_img" "$OUT_RAW"
      echo "squashfs image created: $OUT_RAW"
      return 0
    fi
  fi
  rm -f "$tmp_img"
  return 1
}

if command -v mkfs.erofs >/dev/null 2>&1; then
  create_erofs || true
fi

if [ ! -f "$OUT_RAW" ]; then
  if command -v mksquashfs >/dev/null 2>&1; then
    if ! create_squashfs; then
      echo "mksquashfs failed or produced invalid image." >&2
      exit 1
    fi
  else
    echo "Neither mkfs.erofs nor mksquashfs available. Creating tar.gz fallback (not a valid sysext for systemd-sysext)." >&2
    (cd "$ROOTFS" && tar czf "$TMP/$OUT_RAW.tar.gz" .)
    echo "Created fallback archive: $TMP/$OUT_RAW.tar.gz" >&2
    exit 1
  fi
fi

echo "Image ready: $OUT_RAW"

# Install to host
install_cmd() {
  local src="$SRC_PATH"
  local dest_dir="/var/lib/extensions.d"
  local link_dir="/var/lib/extensions"
  local dest="$dest_dir/$OUT_RAW"
  echo "Installing $src to host under $dest_dir"
  mkdir -p -m0755 "$dest_dir" "$link_dir"
  rm -f "$dest" "$link_dir/${NAME}.raw"
  cp -a "$src" "$dest"
  ln -sf ../extensions.d/"$OUT_RAW" "$link_dir/${NAME}.raw"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-sysext.service || echo "Failed to restart systemd-sysext.service; check logs." >&2
    systemctl daemon-reload || true
    echo "Installed. Run 'systemd-sysext list' to verify, then start the service with 'systemctl start warp-svc.service'"
  else
    echo "systemctl not found: please restart systemd-sysext.service manually." >&2
  fi
}

SRC_PATH="$TMP/$OUT_RAW"
export SRC_PATH OUT_RAW NAME

if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Requesting sudo to install the image on the host..."
    sudo env SRC_PATH="$SRC_PATH" OUT_RAW="$OUT_RAW" NAME="$NAME" bash -c "$(declare -f install_cmd); install_cmd"
  else
    echo "Not running as root and sudo not available. To install the image, run as root:" >&2
    echo "  cp -a $SRC_PATH /var/lib/extensions.d/ && ln -sf ../extensions.d/$OUT_RAW /var/lib/extensions/${NAME}.raw && systemctl restart systemd-sysext.service" >&2
    exit 1
  fi
else
  install_cmd
fi
