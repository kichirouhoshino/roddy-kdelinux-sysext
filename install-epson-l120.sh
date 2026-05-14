#!/usr/bin/env bash
set -euo pipefail

# create_and_install_sysext.sh
# Extracts a local EPSON binary RPM, prepares a sysext rootfs,
# builds a .raw image (erofs preferred, squashfs fallback) and installs it on
# the host under /var/lib/extensions.d/ and /var/lib/extensions/.
#
# WARNING: Run this on the host (not inside a distrobox). The install step
# will require root privileges (the script attempts to use sudo if needed).

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: $0 /path/to/epson-inkjet-printer-201310w-1.0.1-1.x86_64.rpm" >&2
  exit 1
fi
RPM_FILE="$(realpath "$1")"

NAME="epson-inkjet-printer-201310w"
OUT_RAW="${NAME}-1.0.1-1.raw"

echo "This script will: (1) extract the binary RPM, (2) create a sysext .raw, (3) install it on the host."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Working in $TMP"
cd "$TMP"

echo "Using local RPM file: $RPM_FILE"
cp "$RPM_FILE" bin.rpm

echo "Extracting binary RPM using 7z..."
if ! command -v 7z >/dev/null 2>&1; then
  echo "Missing required tool: 7z (p7zip). Install it and retry." >&2
  exit 1
fi

7z x bin.rpm >/dev/null
if [ -n "$(find . -maxdepth 1 -name '*.cpio' -print -quit)" ]; then
  for c in *.cpio; do
    echo "Extracting payload $c..."
    7z x "$c" >/dev/null || true
  done
fi

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
    echo "Cannot continue installation because systemd-sysext expects a filesystem image." >&2
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
  # Remove the existing destination to prevent "Text file busy" errors if it's currently mounted
  rm -f "$dest" "$link_dir/${NAME}.raw"
  cp -a "$src" "$dest"
  ln -sf ../extensions.d/"$OUT_RAW" "$link_dir/${NAME}.raw"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-sysext.service || echo "Failed to restart systemd-sysext.service; check logs." >&2
  else
    echo "systemctl not found: please restart systemd-sysext.service manually." >&2
  fi
  echo "Installed and attempted to restart systemd-sysext.service. Run 'systemd-sysext list' to verify." 
}

SRC_PATH="$TMP/$OUT_RAW"
export SRC_PATH

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

echo "All done. You can inspect installed extensions with: systemd-sysext list; check status with: systemd-sysext status"
