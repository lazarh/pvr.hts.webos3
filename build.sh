#!/usr/bin/env bash
#
# build.sh - cross-compile the Kodi "pvr.hts" (Tvheadend HTSP) binary add-on
#            for LG webOS on 32-bit ARM (arm-webos-linux-gnueabi / ARMv7).
#
# The add-on is built against the official Kodi webOS build system:
#   https://github.com/xbmc/xbmc/blob/master/docs/README.webOS.md
#
# A Kodi built from xbmc/xbmc master with ADDON_API 22.90.701 (the version used
# by the installed org.xbmc.kodi_22.90.701_arm-WEBOS-3-plus ipk) is targeted by
# default. The result is dist/pvr.hts-webos-armv7.zip.
#
# Environment overrides:
#   KODI_REPO           git URL of the Kodi tree      (default: xbmc/xbmc)
#   KODI_REF            branch/tag/commit to build    (default: pinned master
#                       commit with ADDON_API 22.90.701; use "master" to track)
#   EXPECTED_ADDON_API  expected ADDON_API version    (default: 22.90.701)
#   SDK_TAG             openlgtv/buildroot-nc4 tag    (default: 2026.08-webos)
#   SDK_ASSET           SDK tarball asset name        (arch specific)
#   SDK_SHA256          expected SDK tarball checksum (default set for the
#                       default tag/asset, empty otherwise)
#   SDK_URL             full SDK tarball URL          (overrides tag/asset)
#   TARGET_HOST         toolchain triple              (default: arm-webos-linux-gnueabi)
#   ADDON               add-on id to build            (default: pvr.hts)
#   BUILD_DIR           working directory             (default: ./build)
#   DIST_DIR            output directory              (default: ./dist)
#   OUTPUT_NAME         zip file name                 (default: pvr.hts-webos-armv7.zip)
#   JOBS                parallel make jobs            (default: number of CPUs)
#
# Flags:
#   --no-deps   do not install Ubuntu/Debian build dependencies
#   --clean     remove the build and dist directories first
#   -h, --help  show this help
#
set -euo pipefail

trap 'printf "ERROR: build failed at line %s\n" "$LINENO" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
KODI_REPO="${KODI_REPO:-https://github.com/xbmc/xbmc.git}"

# xbmc/xbmc master as of 2026-11-14; version.txt says:
#   VERSION_MAJOR 23 / VERSION_TAG ALPHA1 / ADDON_API 22.90.701
# This matches the ADDON_API of the precompiled Kodi 22.90.701 webOS build.
# Set KODI_REF=master to follow upstream (only safe while ADDON_API stays
# 22.90.701), or pin the exact commit shown in your kodi.log.
KODI_REF="${KODI_REF:-623f24ad8cf0c6ceb4a4eaeadc8fea7875239343}"
EXPECTED_ADDON_API="${EXPECTED_ADDON_API:-22.90.701}"

DEFAULT_SDK_TAG="2026.08-webos"
DEFAULT_SDK_ASSET="arm-webos-linux-gnueabi_sdk-buildroot-x86_64.tar.gz"
DEFAULT_SDK_SHA256="2230a6351e5cce6fcb9d4fdcb4697335f223995401ef969c81744aaeb14c5344"

SDK_TAG="${SDK_TAG:-$DEFAULT_SDK_TAG}"
SDK_ASSET="${SDK_ASSET:-$DEFAULT_SDK_ASSET}"
SDK_SHA256="${SDK_SHA256:-}"
if [[ -z "$SDK_SHA256" && "$SDK_TAG" == "$DEFAULT_SDK_TAG" && "$SDK_ASSET" == "$DEFAULT_SDK_ASSET" ]]; then
  SDK_SHA256="$DEFAULT_SDK_SHA256"
fi
SDK_URL="${SDK_URL:-https://github.com/openlgtv/buildroot-nc4/releases/download/${SDK_TAG}/${SDK_ASSET}}"

TARGET_HOST="${TARGET_HOST:-arm-webos-linux-gnueabi}"
ADDON="${ADDON:-pvr.hts}"

BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
OUTPUT_NAME="${OUTPUT_NAME:-pvr.hts-webos-armv7.zip}"

if [[ -z "${JOBS:-}" ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2)"
fi
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
  printf 'Invalid JOBS value: %s\n' "$JOBS" >&2
  exit 1
fi

INSTALL_DEPS=1
CLEAN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
build.sh - cross-compile the Kodi pvr.hts add-on for LG webOS (ARMv7)

Produces dist/pvr.hts-webos-armv7.zip, installable on a TV running a
Kodi webOS ARM build with ADDON_API 22.90.701 (xbmc/xbmc master).

Usage: ./build.sh [--no-deps] [--clean] [--help]

Flags:
  --no-deps   do not install Ubuntu/Debian build dependencies
  --clean     remove the build and dist directories first
  -h, --help  show this help

Environment overrides: KODI_REPO, KODI_REF, EXPECTED_ADDON_API, SDK_TAG,
SDK_ASSET, SDK_SHA256, SDK_URL, TARGET_HOST, ADDON, BUILD_DIR, DIST_DIR,
OUTPUT_NAME, JOBS (see the header of this script for details).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --no-deps) INSTALL_DEPS=0 ;;
    --clean)   CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 0: optional cleanup
# ---------------------------------------------------------------------------
if (( CLEAN )); then
  log "Cleaning $BUILD_DIR and $DIST_DIR"
  rm -rf -- "$BUILD_DIR" "$DIST_DIR"
fi

mkdir -p -- "$BUILD_DIR" "$DIST_DIR"

# ---------------------------------------------------------------------------
# Step 1: build dependencies (Ubuntu / Debian)
# ---------------------------------------------------------------------------
install_deps() {
  local apt_cmd=()
  if [[ $EUID -eq 0 ]]; then
    apt_cmd=(apt-get)
  elif command -v sudo >/dev/null 2>&1; then
    apt_cmd=(sudo apt-get)
  else
    warn "sudo not available; skipping dependency installation"
    return 0
  fi

  local pkgs=(
    autoconf automake autopoint autotools-dev libtool pkg-config
    gettext gawk gperf bison flex texinfo patch
    gcc g++ make ccache
    cmake meson ninja-build nasm yasm
    git curl wget ca-certificates xz-utils bzip2 zip unzip rsync file
    python3 python3-dev python3-pip python3-setuptools
    libssl-dev zlib1g-dev libffi-dev libxml2-dev libxslt1-dev
    libcurl4-openssl-dev libcrypt-dev libncurses-dev
  )

  log "Installing build dependencies (apt)"
  "${apt_cmd[@]}" update -qq || warn "apt-get update failed; continuing"

  if "${apt_cmd[@]}" install -y -qq --no-install-recommends "${pkgs[@]}"; then
    info "all dependency packages installed"
    return 0
  fi

  warn "bulk install failed; retrying package by package (skipping unavailable ones)"
  local p missing=()
  for p in "${pkgs[@]}"; do
    if ! "${apt_cmd[@]}" install -y -qq --no-install-recommends "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done
  if (( ${#missing[@]} )); then
    warn "packages not installed (probably not available on this distro): ${missing[*]}"
  fi
}

if (( INSTALL_DEPS )); then
  if command -v apt-get >/dev/null 2>&1; then
    install_deps
  else
    warn "apt-get not found; install the dependencies listed in README.md manually"
  fi
fi

for cmd in git make cmake tar curl unzip; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
done

# Fast preflight checks for headers needed by the native (host) tool builds.
# Without them the dependency build fails many minutes in.
missing_headers=()
if ! compgen -G "/usr/include/curl/curl.h" >/dev/null 2>&1 \
   && ! compgen -G "/usr/include/*/curl/curl.h" >/dev/null 2>&1; then
  missing_headers+=("curl.h (install libcurl4-openssl-dev / libcurl-devel)")
fi
if [[ ! -f /usr/include/crypt.h ]]; then
  missing_headers+=("crypt.h (install libcrypt-dev / libxcrypt-devel)")
fi
if (( ${#missing_headers[@]} )); then
  die "missing build headers: ${missing_headers[*]}"
fi

# ---------------------------------------------------------------------------
# Step 2: webOS toolchain (buildroot-nc4, arm-webos-linux-gnueabi)
# ---------------------------------------------------------------------------
TOOLCHAIN_PARENT="$BUILD_DIR/toolchain"
TOOLCHAIN_SDK_ROOT="$TOOLCHAIN_PARENT/sdk"
TOOLCHAIN_TARBALL="$TOOLCHAIN_PARENT/$SDK_ASSET"

log "Preparing webOS toolchain ($SDK_TAG)"
mkdir -p -- "$TOOLCHAIN_PARENT"

if [[ ! -f "$TOOLCHAIN_TARBALL" ]]; then
  info "downloading $SDK_URL"
  curl -fL --retry 3 --retry-delay 5 -C - -o "$TOOLCHAIN_TARBALL" "$SDK_URL"
else
  info "using cached $(basename "$TOOLCHAIN_TARBALL")"
fi

if [[ -n "$SDK_SHA256" ]]; then
  info "verifying checksum"
  printf '%s  %s\n' "$SDK_SHA256" "$TOOLCHAIN_TARBALL" | sha256sum -c - >/dev/null \
    || die "SDK tarball checksum mismatch (delete $TOOLCHAIN_TARBALL and retry)"
fi

if [[ ! -f "$TOOLCHAIN_SDK_ROOT/.extracted" ]]; then
  info "extracting SDK (this can take a few minutes)"
  rm -rf -- "$TOOLCHAIN_SDK_ROOT"
  mkdir -p -- "$TOOLCHAIN_SDK_ROOT"
  tar -xzf "$TOOLCHAIN_TARBALL" -C "$TOOLCHAIN_SDK_ROOT"
  touch "$TOOLCHAIN_SDK_ROOT/.extracted"
fi

detect_toolchain() {
  local root="$1" dir
  for dir in "$root"/*; do
    [[ -d "$dir" ]] || continue
    if { [[ -e "$dir/usr/bin/$TARGET_HOST-gcc" ]] || [[ -e "$dir/bin/$TARGET_HOST-gcc" ]]; } \
       && [[ -d "$dir/usr/include" || -d "$dir/include" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

if ! TOOLCHAIN_DIR="$(detect_toolchain "$TOOLCHAIN_SDK_ROOT")"; then
  ls -la "$TOOLCHAIN_SDK_ROOT" >&2 || true
  die "could not locate a '$TARGET_HOST' toolchain in $TOOLCHAIN_SDK_ROOT"
fi
info "toolchain: $TOOLCHAIN_DIR"

# ---------------------------------------------------------------------------
# Step 3: Kodi source tree
# ---------------------------------------------------------------------------
SRC_DIR="$BUILD_DIR/xbmc"

log "Fetching Kodi source ($KODI_REF)"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$KODI_REPO" "$SRC_DIR"
fi

git -C "$SRC_DIR" remote set-url origin "$KODI_REPO"
git -C "$SRC_DIR" fetch --tags --prune origin

if git -C "$SRC_DIR" rev-parse --verify --quiet "refs/remotes/origin/$KODI_REF" >/dev/null; then
  git -C "$SRC_DIR" checkout --force -B "$KODI_REF" "refs/remotes/origin/$KODI_REF"
else
  # Tag or commit: make sure the object is present before checking out.
  if ! git -C "$SRC_DIR" rev-parse --verify --quiet "${KODI_REF}^{commit}" >/dev/null; then
    git -C "$SRC_DIR" fetch origin "$KODI_REF" \
      || die "'$KODI_REF' is not a branch, tag or commit reachable from $KODI_REPO"
  fi
  git -C "$SRC_DIR" checkout --force --detach "$KODI_REF"
fi

KODI_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
info "checked out $(git -C "$SRC_DIR" describe --always --dirty --tags 2>/dev/null || echo "$KODI_SHA") ($KODI_SHA)"

KODI_ADDON_API="$(awk '$1 == "ADDON_API" { print $2; exit }' "$SRC_DIR/version.txt")"
if [[ -n "$KODI_ADDON_API" && "$KODI_ADDON_API" != "$EXPECTED_ADDON_API" ]]; then
  warn "Kodi tree reports ADDON_API=$KODI_ADDON_API, expected $EXPECTED_ADDON_API."
  warn "The add-on will not load on a Kodi $EXPECTED_ADDON_API build. Pin KODI_REF accordingly."
else
  info "ADDON_API: $KODI_ADDON_API (ok)"
fi

# A different Kodi commit means stale dependency binaries: rebuild them.
SHA_MARK="$BUILD_DIR/.kodi-sha"
if [[ -f "$SHA_MARK" && "$(cat "$SHA_MARK")" != "$KODI_SHA" ]]; then
  log "Kodi ref changed - cleaning the dependency build tree"
  make -C "$SRC_DIR/tools/depends" distclean >/dev/null 2>&1 || true
  rm -rf -- "$BUILD_DIR/kodi-deps" "$BUILD_DIR/.depends-configure"
fi
printf '%s\n' "$KODI_SHA" > "$SHA_MARK"

# ---------------------------------------------------------------------------
# Step 4: tools/depends (cross build of all Kodi dependencies)
# ---------------------------------------------------------------------------
DEPS_PREFIX="$BUILD_DIR/kodi-deps"
TARBALLS_DIR="$BUILD_DIR/tarballs"
mkdir -p -- "$DEPS_PREFIX" "$TARBALLS_DIR"

log "Bootstrapping tools/depends"
if [[ ! -x "$SRC_DIR/tools/depends/configure" ]]; then
  ( cd "$SRC_DIR/tools/depends" && ./bootstrap )
else
  info "configure already generated"
fi

CONF_MARK="$BUILD_DIR/.depends-configure"
CONF_LINE="$TARGET_HOST|$TOOLCHAIN_DIR|$DEPS_PREFIX"
if [[ ! -f "$CONF_MARK" || "$(cat "$CONF_MARK")" != "$CONF_LINE" ]]; then
  log "Configuring tools/depends for $TARGET_HOST"
  ( cd "$SRC_DIR/tools/depends" && ./configure \
      --prefix="$DEPS_PREFIX" \
      --host="$TARGET_HOST" \
      --with-toolchain="$TOOLCHAIN_DIR" \
      --with-tarballs="$TARBALLS_DIR" \
      --enable-debug=no )
  printf '%s\n' "$CONF_LINE" > "$CONF_MARK"
else
  info "tools/depends already configured for this toolchain"
fi

log "Building Kodi dependencies (first run: 1-3 hours, later runs are incremental)"
if ! ( cd "$SRC_DIR/tools/depends" && make -j"$JOBS" ); then
  warn "the dependency build failed."
  warn "re-run ./build.sh to resume; to retry a single dependency run:"
  warn "  make -C $SRC_DIR/tools/depends/target/<name> distclean"
  exit 1
fi
info "dependencies built successfully"

# ---------------------------------------------------------------------------
# Step 5: build the pvr.hts binary add-on
# ---------------------------------------------------------------------------
# The official webOS flow installs add-ons below <PREFIX>/addons and expects
# the dependency libraries under <PREFIX>/{lib,include,share} (this mirrors the
# tools/webOS/packaging directory of a full Kodi build).
PKG_DIR="$BUILD_DIR/packaging"
mkdir -p -- "$PKG_DIR"
for sub in lib include share; do
  if [[ -d "$DEPS_PREFIX/$sub" && ! -e "$PKG_DIR/$sub" ]]; then
    ln -s "$DEPS_PREFIX/$sub" "$PKG_DIR/$sub"
  fi
done

ADDONS_TARGET_DIR="$SRC_DIR/tools/depends/target/binary-addons"
# Force re-packaging so the zip is always (re)created, even on re-runs.
find "$ADDONS_TARGET_DIR" -maxdepth 1 -name '.installed-*' -delete 2>/dev/null || true

log "Building add-on: $ADDON"
( cd "$ADDONS_TARGET_DIR" && make -j"$JOBS" \
    PREFIX="$PKG_DIR" \
    ADDONS="$ADDON" \
    PACKAGE=1 )

[[ -d "$PKG_DIR/addons/$ADDON" ]] || die "add-on was not installed to $PKG_DIR/addons/$ADDON"

# ---------------------------------------------------------------------------
# Step 6: package the result
# ---------------------------------------------------------------------------
log "Packaging $OUTPUT_NAME"
OUT_ZIP="$DIST_DIR/$OUTPUT_NAME"
rm -f -- "$OUT_ZIP"

# Archive the installed add-on ourselves: the build system's CPack zip keeps the
# versioned library files as symlinks, which webOS Dev Manager uploads do not
# always preserve. Info-ZIP dereferences symlinks by default, so this archive
# contains a real pvr.hts.so that survives being copied folder-by-folder.
command -v zip >/dev/null 2>&1 || die "'zip' is required to package the add-on"
( cd "$PKG_DIR/addons" && zip -qr "$OUT_ZIP" "$ADDON" )
info "created archive from $PKG_DIR/addons/$ADDON"

# Sanity check the archive layout (Kodi expects <addon-id>/addon.xml at the root)
python3 - "$OUT_ZIP" "$ADDON" <<'PY'
import sys
import zipfile

zip_path, addon = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as archive:
    names = archive.namelist()

if f"{addon}/addon.xml" not in names:
    sys.exit(f"ERROR: {zip_path} does not contain {addon}/addon.xml")
if not any(n.startswith(f"{addon}/") and n.endswith(".so") for n in names):
    sys.exit(f"ERROR: {zip_path} does not contain the {addon} shared library")
print(f"    archive layout ok ({len(names)} entries)")
PY

if command -v unzip >/dev/null 2>&1; then
  info "addon.xml requirements stamped from the Kodi tree:"
  unzip -p "$OUT_ZIP" "$ADDON/addon.xml" \
    | grep -oE '<import [^>]*/>' \
    | sed 's/^/      /' || true
fi

SHA256_OUT="$(sha256sum "$OUT_ZIP" | cut -d' ' -f1)"

log "Done"
info "file:   $OUT_ZIP"
info "size:   $(du -h "$OUT_ZIP" | cut -f1)"
info "sha256: $SHA256_OUT"
info "kodi:   ADDON_API $KODI_ADDON_API @ $KODI_SHA"
printf '\nInstall: unzip %s and copy the "%s" folder into\n' "$(basename "$OUT_ZIP")" "$ADDON"
printf '  /media/developer/apps/usr/palm/applications/org.xbmc.kodi/addons/\n'
printf 'on the TV (webOS Dev Manager file browser), then restart Kodi.\n'
