#!/bin/bash
set -euo pipefail

# ==============================================================================
# Astra Linux ISO to Docker Image Builder (Multi-Version & Multi-Preset)
# Modeled after redos-iso-docker-patch
# ==============================================================================
# Usage:
#   ./build.sh [OPTIONS] [iso_file_or_url ...]
#
# Options:
#   -p, --preset <server|minimal>  Preset to build (default: server)
#   --include <pkg1,pkg2,...>      Additional packages to install
#   --with-ssh                     Ensure openssh-server is included
#   --prefix <image_repo>          Image repository name (default: runalsh/astra-iso-patch)
#   --force                        Skip registry check and force rebuild
#   --push-dockerhub               Push built images to Docker Hub
#   --push-ghcr                    Push built images to GitHub Container Registry
#   --no-cleanup                   Keep local Docker images after build
#   -h, --help                     Show this help message
# ==============================================================================

IMAGE_NAME="${IMAGE_NAME:-runalsh/astra-iso-patch}"
RELEASES_FILE="${RELEASES_FILE:-releases.txt}"
PRESET_CHOICE="server"
EXTRA_INCLUDE_PKGS=""
SKIP_EXISTS_CHECK="${SKIP_EXISTS_CHECK:-false}"
PUSH_TO_DOCKERHUB="${PUSH_TO_DOCKERHUB:-false}"
PUSH_TO_GHCR="${PUSH_TO_GHCR:-false}"
CLEANUP_DOCKER_IMAGES="${CLEANUP_DOCKER_IMAGES:-false}"
TEST_VERSION="${TEST_VERSION:-true}"
CLI_ISOS=()

# Terminal colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_MAGENTA="\033[1;35m"
C_GRAY="\033[0;90m"

# Sudo helper for commands requiring root
s() {
  if [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null; then
    sudo "$@"
  else
    "$@"
  fi
}

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log_info()    { echo -e "${C_CYAN}[$(ts)]${C_RESET} ${C_BLUE}[INFO]${C_RESET} $*"; }
log_step()    { echo -e "\n${C_CYAN}[$(ts)]${C_RESET} ${C_MAGENTA}${C_BOLD}===> $*$C_RESET"; }
log_exec()    { echo -e "${C_CYAN}[$(ts)]${C_RESET} ${C_GRAY}[EXEC] + $*$C_RESET"; }
log_success() { echo -e "${C_CYAN}[$(ts)]${C_RESET} ${C_GREEN}[SUCCESS]${C_RESET} $*"; }
log_warn()    { echo -e "${C_CYAN}[$(ts)]${C_RESET} ${C_YELLOW}[WARNING]${C_RESET} $*"; }
log_error()   { echo -e "${C_CYAN}[$(ts)]${C_RESET} ${C_RED}[ERROR]${C_RESET} $*"; }

ensure_host_dependencies() {
  local missing=()
  command -v debootstrap &>/dev/null || missing+=(debootstrap)
  command -v dpkg &>/dev/null        || missing+=(dpkg)
  command -v curl &>/dev/null        || missing+=(curl)
  command -v tar &>/dev/null         || missing+=(tar)
  command -v gzip &>/dev/null        || missing+=(gzip)
  command -v xz &>/dev/null          || missing+=(xz)
  command -v ar &>/dev/null          || missing+=(binutils)

  if [ ${#missing[@]} -gt 0 ]; then
    log_info "Installing missing host dependencies: ${missing[*]}..."
    if command -v apt-get &>/dev/null; then
      s apt-get update -qq || true
      s apt-get install -y -qq "${missing[@]}" || true
    elif command -v dnf &>/dev/null; then
      s dnf install -y -q "${missing[@]}" || true
    elif command -v yum &>/dev/null; then
      s yum install -y -q "${missing[@]}" || true
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--preset)
      PRESET_CHOICE="$2"
      shift 2
      ;;
    --preset=*)
      PRESET_CHOICE="${1#*=}"
      shift 1
      ;;
    --include)
      EXTRA_INCLUDE_PKGS="$2"
      shift 2
      ;;
    --include=*)
      EXTRA_INCLUDE_PKGS="${1#*=}"
      shift 1
      ;;
    --with-ssh)
      if [ -z "$EXTRA_INCLUDE_PKGS" ]; then
        EXTRA_INCLUDE_PKGS="openssh-server"
      else
        EXTRA_INCLUDE_PKGS="${EXTRA_INCLUDE_PKGS},openssh-server"
      fi
      shift 1
      ;;
    --prefix)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --force)
      SKIP_EXISTS_CHECK="true"
      shift 1
      ;;
    --push-dockerhub)
      PUSH_TO_DOCKERHUB="true"
      shift 1
      ;;
    --push-ghcr)
      PUSH_TO_GHCR="true"
      shift 1
      ;;
    --no-cleanup)
      CLEANUP_DOCKER_IMAGES="false"
      shift 1
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS] [iso_file_or_url ...]"
      echo "  -p, --preset <name>       Preset to build (server|minimal, default: server)"
      echo "  --include <packages>      Comma-separated list of extra packages to install"
      echo "  --with-ssh                Ensure openssh-server is included"
      echo "  --prefix <repo>           Image repository name (default: runalsh/astra-iso-patch)"
      echo "  --force                   Force rebuild even if tag exists in remote registry"
      echo "  --push-dockerhub          Push images to Docker Hub"
      echo "  --push-ghcr               Push images to GHCR"
      echo "  --no-cleanup              Preserve local Docker images after build"
      exit 0
      ;;
    *)
      CLI_ISOS+=("$1")
      shift 1
      ;;
  esac
done

ensure_host_dependencies

declare -a TARGETS=()

if [ ${#CLI_ISOS[@]} -gt 0 ]; then
  for item in "${CLI_ISOS[@]}"; do
    if [[ "$item" =~ ^https?:// ]]; then
      tag=$(basename "$item" .iso | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "latest")
      TARGETS+=("$tag|$item")
    elif [ -f "$item" ]; then
      tag=$(basename "$item" .iso | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "latest")
      TARGETS+=("$tag|$item")
    else
      log_warn "File '$item' not found, skipping."
    fi
  done
elif [ -f "$RELEASES_FILE" ]; then
  while read -r tag url || [ -n "$tag" ]; do
    [[ -z "$tag" || "$tag" =~ ^# ]] && continue
    TARGETS+=("$tag|$url")
  done < "$RELEASES_FILE"
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  log_error "Neither populated $RELEASES_FILE nor valid CLI ISO arguments were provided!"
  echo "Example usage:"
  echo "  $0 /path/to/astra-installation.iso"
  echo "  $0 --preset minimal /path/to/astra-installation.iso"
  exit 1
fi

echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}Astra Linux ISO Docker Multi-Release Builder${C_RESET}"
echo -e "Repository:            ${C_YELLOW}${IMAGE_NAME}${C_RESET}"
echo -e "Preset:                ${C_YELLOW}${PRESET_CHOICE}${C_RESET}"
if [ -n "$EXTRA_INCLUDE_PKGS" ]; then
  echo -e "Extra packages:        ${C_YELLOW}${EXTRA_INCLUDE_PKGS}${C_RESET}"
fi
echo -e "Releases in queue:     ${#TARGETS[@]}"
echo -e "Push to Docker Hub:    ${PUSH_TO_DOCKERHUB}"
echo -e "Push to GHCR:          ${PUSH_TO_GHCR}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"

global_cleanup() {
  log_info "Running cleanup of leftover mounts and temporary files..."
  for m in $(mount 2>/dev/null | grep -E '/tmp/astra-iso-patch_' | awk '{print $3}' || true); do
    s umount -f "$m" 2>/dev/null || true
  done
  s rm -rf /tmp/astra-iso-patch_* 2>/dev/null || true
}
global_cleanup

SUCCESS_TAGS=()

for target in "${TARGETS[@]}"; do
  tag="${target%%|*}"
  source="${target##*|}"

  log_step "Processing release: tag='${tag}', source='${source}'"

  FULL_IMAGE_TAG="${IMAGE_NAME}:${tag}-${PRESET_CHOICE}"
  GHCR_IMAGE_NAME="ghcr.io/$(echo "${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]')"
  FULL_GHCR_TAG="${GHCR_IMAGE_NAME}:${tag}-${PRESET_CHOICE}"

  # Remote registry check
  if [ "$SKIP_EXISTS_CHECK" != "true" ]; then
    dh_exists=false
    ghcr_exists=false
    if [ "$PUSH_TO_DOCKERHUB" = "true" ]; then
      if docker manifest inspect "${FULL_IMAGE_TAG}" &>/dev/null || curl -sfSL "https://hub.docker.com/v2/repositories/${IMAGE_NAME}/tags/${tag}-${PRESET_CHOICE}/" &>/dev/null; then
        dh_exists=true
      fi
    else
      dh_exists=true
    fi
    if [ "$PUSH_TO_GHCR" = "true" ]; then
      if docker manifest inspect "${FULL_GHCR_TAG}" &>/dev/null; then
        ghcr_exists=true
      fi
    else
      ghcr_exists=true
    fi
    if [ "$dh_exists" = "true" ] && [ "$ghcr_exists" = "true" ] && { [ "$PUSH_TO_DOCKERHUB" = "true" ] || [ "$PUSH_TO_GHCR" = "true" ]; }; then
      log_success "Tag ${FULL_IMAGE_TAG} already exists on all enabled registries. Skipping build."
      continue
    fi
  fi

  RAND_ID=$(head /dev/urandom | tr -dc a-z0-9 | head -c 8 ; echo '')
  LOCAL_ISO=""
  MNT_DIR="/tmp/astra-iso-patch_iso_mnt_${RAND_ID}"
  ROOTFS_DIR="/tmp/astra-iso-patch_rootfs_${RAND_ID}"
  HELPER_DIR="/tmp/astra-iso-patch_helper_${RAND_ID}"

  cleanup_run() {
    log_info "Cleaning up temporary mount points and rootfs directory..."
    s umount -f "$ROOTFS_DIR/media/iso" 2>/dev/null || true
    s umount -f "$MNT_DIR" 2>/dev/null || true
    s rm -rf "$MNT_DIR" "$ROOTFS_DIR" "$HELPER_DIR"
    if [[ "$source" =~ ^https?:// ]] && [ -f "${LOCAL_ISO:-}" ]; then
      log_info "Removing downloaded temporary ISO: $LOCAL_ISO"
      rm -f "$LOCAL_ISO"
    fi
    if [ "${CLEANUP_DOCKER_IMAGES:-false}" = "true" ]; then
      log_info "Pruning local Docker images for this tag to free disk space..."
      docker rmi -f "${FULL_IMAGE_TAG}" "${FULL_GHCR_TAG}" 2>/dev/null || true
      for extra_tag in "${ALL_EXTRA_TAGS[@]:-}"; do
        docker rmi -f "${IMAGE_NAME}:${extra_tag}-${PRESET_CHOICE}" "${GHCR_IMAGE_NAME}:${extra_tag}-${PRESET_CHOICE}" 2>/dev/null || true
        docker rmi -f "${IMAGE_NAME}:${extra_tag}" "${GHCR_IMAGE_NAME}:${extra_tag}" 2>/dev/null || true
      done
    fi
  }
  trap cleanup_run EXIT INT TERM HUP

  s mkdir -p "$MNT_DIR" "$ROOTFS_DIR" "$HELPER_DIR"

  if [[ "$source" =~ ^https?:// ]]; then
    fname=$(basename "$source")
    if [ -f "/$fname" ]; then
      LOCAL_ISO="/$fname"
      log_info "Found local cached ISO: $LOCAL_ISO (download skipped)"
    elif [ -f "./$fname" ]; then
      LOCAL_ISO="./$fname"
      log_info "Found local cached ISO: $LOCAL_ISO (download skipped)"
    else
      LOCAL_ISO="/tmp/astra-iso-patch_download_${RAND_ID}.iso"
      log_info "Downloading ISO from ${source}..."
      log_exec "curl -fLC - -sS --show-error -o $LOCAL_ISO $source"
      curl -fLC - -sS --show-error -o "$LOCAL_ISO" "$source"
      ISO_SIZE=$(du -h "$LOCAL_ISO" | awk '{print $1}')
      log_success "Download complete. File size: ${ISO_SIZE}"
    fi
  else
    LOCAL_ISO="$source"
  fi

  log_info "Mounting ISO image..."
  s mount -o loop,ro "$LOCAL_ISO" "$MNT_DIR"

  # Detect codename from dists
  DETECTED_CODENAME=""
  if [ -d "$MNT_DIR/dists" ]; then
    DETECTED_CODENAME=$(find "$MNT_DIR/dists" -mindepth 1 -maxdepth 1 -type d ! -name 'stable' -exec basename {} \; | head -n1 || true)
  fi
  if [ -z "$DETECTED_CODENAME" ]; then
    DETECTED_CODENAME="1.8_x86-64"
  fi

  # Detect version string from ISO .info files
  DETECTED_VERSION=""
  INFO_FILE=$(find "$MNT_DIR" -maxdepth 1 -name "*.info" 2>/dev/null | head -n1 || true)
  if [ -n "$INFO_FILE" ] && [ -f "$INFO_FILE" ]; then
    DETECTED_VERSION=$(grep -oE '1\.[0-9]+(\.[0-9]+)?' "$INFO_FILE" | head -n1 || true)
  fi
  if [ -z "$DETECTED_VERSION" ] && [ -f "$MNT_DIR/.disk/info" ]; then
    DETECTED_VERSION=$(grep -oE '1\.[0-9]+(\.[0-9]+)?' "$MNT_DIR/.disk/info" | head -n1 || true)
  fi
  if [ -z "$DETECTED_VERSION" ]; then
    DETECTED_VERSION="$tag"
  fi

  log_info "Detected ISO Codename: ${DETECTED_CODENAME}, Version: ${DETECTED_VERSION}"

  log_step "Extracting Astra Linux native debootstrap package from ISO"
  DEBOOTSTRAP_DEB=$(find "$MNT_DIR/pool" -type f -name "debootstrap_*.deb" 2>/dev/null | head -n1 || true)
  if [ -n "$DEBOOTSTRAP_DEB" ] && [ -f "$DEBOOTSTRAP_DEB" ]; then
    log_info "Found Astra debootstrap: $DEBOOTSTRAP_DEB"
    (
      cd "$HELPER_DIR"
      ar -x "$DEBOOTSTRAP_DEB"
      tar -xf data.tar.*
    )
    DEBOOTSTRAP_BIN="$HELPER_DIR/usr/sbin/debootstrap"
    DEBOOTSTRAP_DIR_PATH="$HELPER_DIR/usr/share/debootstrap"
  else
    DEBOOTSTRAP_BIN="$(command -v debootstrap)"
    DEBOOTSTRAP_DIR_PATH="/usr/share/debootstrap"
  fi

  log_step "Bootstrapping base Astra Linux rootfs via debootstrap"
  log_exec "debootstrap --no-check-gpg --include=sudo,curl,ca-certificates ${DETECTED_CODENAME} ${ROOTFS_DIR} file://${MNT_DIR}"

  DEBOOTSTRAP_DIR="$DEBOOTSTRAP_DIR_PATH" s "$DEBOOTSTRAP_BIN" \
    --no-check-gpg \
    --include="sudo,curl,ca-certificates" \
    "${DETECTED_CODENAME}" \
    "${ROOTFS_DIR}" \
    "file://${MNT_DIR}"

  log_step "Configuring container chroot and mounting ISO repository"
  s mkdir -p "$ROOTFS_DIR/media/iso"
  s mount --bind "$MNT_DIR" "$ROOTFS_DIR/media/iso"

  # Prevent services from automatically starting inside chroot during package install
  cat << 'EOF_POLICY' | s tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
#!/bin/sh
exit 101
EOF_POLICY
  s chmod +x "$ROOTFS_DIR/usr/sbin/policy-rc.d"

  # Setup temporary offline APT repo for chroot
  cat << EOF_APTLIST | s tee "$ROOTFS_DIR/etc/apt/sources.list" >/dev/null
deb [trusted=yes] file:/media/iso ${DETECTED_CODENAME} main contrib non-free non-free-firmware
EOF_APTLIST

  s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update -qq

  if [ "$PRESET_CHOICE" = "server" ]; then
    log_step "Installing Server preset (Base tools + SSH + Astra SE utilities; excluding kernel/firmware/cups bloat)"
    
    SERVER_PKGS=(
      # Base Administration & Console tools (Task: Base)
      mc mc-data vim vim-runtime bash-completion p7zip-full 7zip unzip
      lsof rsync wget bzip2 xz-utils zstd psmisc locales less nano bc file acl attr
      # Network & SSH Server (Task: Fly-ssh)
      openssh-server openssh-client openssh-sftp-server ufw iptables ethtool
      # Astra Linux Special Edition Parsec & Security utilities
      parsec-mac parsec-cap parsec-aud parsec-base parsec-sudo
      astra-update astra-safepolicy astra-sosreport
    )

    if [ -n "$EXTRA_INCLUDE_PKGS" ]; then
      IFS=',' read -ra ADDS <<< "$EXTRA_INCLUDE_PKGS"
      SERVER_PKGS+=("${ADDS[@]}")
    fi

    log_exec "apt-get install -y --no-install-recommends ${SERVER_PKGS[*]}"
    s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
      apt-get install -y -qq --no-install-recommends "${SERVER_PKGS[@]}" || {
        log_warn "Some non-essential packages failed, installing core server utilities..."
        s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
          apt-get install -y -qq --no-install-recommends \
            mc vim bash-completion p7zip-full unzip lsof rsync wget openssh-server ufw parsec-base || true
      }
  elif [ -n "$EXTRA_INCLUDE_PKGS" ]; then
    log_step "Installing user-specified packages: ${EXTRA_INCLUDE_PKGS}"
    IFS=',' read -ra ADDS <<< "$EXTRA_INCLUDE_PKGS"
    s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
      apt-get install -y -qq --no-install-recommends "${ADDS[@]}"
  fi

  # Generate and configure system locales
  s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
    sh -c '
      if [ -f /etc/locale.gen ]; then
        echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
        echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        sort -u -o /etc/locale.gen /etc/locale.gen
        locale-gen 2>/dev/null || true
      fi
      if command -v update-locale >/dev/null 2>&1; then
        update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8 2>/dev/null || true
      fi
    '

  # Cleanup chroot setup
  s umount -f "$ROOTFS_DIR/media/iso" 2>/dev/null || true
  s rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  s rm -rf "$ROOTFS_DIR/media/iso"

  log_step "Deep optimization of rootfs for Docker container"
  log_exec "Purging any accidental kernel modules, boot images, and firmware..."
  s rm -rf "$ROOTFS_DIR"/boot/* "$ROOTFS_DIR"/usr/lib/modules/* "$ROOTFS_DIR"/lib/modules/* 2>/dev/null || true
  s rm -rf "$ROOTFS_DIR"/usr/lib/firmware/* "$ROOTFS_DIR"/lib/firmware/* 2>/dev/null || true

  log_exec "Purging documentation, man pages, caches, and temporary files..."
  s rm -rf "$ROOTFS_DIR"/var/cache/apt/* "$ROOTFS_DIR"/var/lib/apt/lists/* "$ROOTFS_DIR"/var/log/* "$ROOTFS_DIR"/tmp/* "$ROOTFS_DIR"/var/tmp/* 2>/dev/null || true
  s rm -rf "$ROOTFS_DIR"/usr/share/doc/* "$ROOTFS_DIR"/usr/share/man/* "$ROOTFS_DIR"/usr/share/info/* 2>/dev/null || true

  log_exec "Stripping non-RU / non-EN locales (preserving ru*, en*, and POSIX)..."
  if [ -d "$ROOTFS_DIR/usr/share/locale" ]; then
    find "$ROOTFS_DIR/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'ru*' ! -name 'en*' ! -name 'POSIX' -exec rm -rf {} + 2>/dev/null || true
  fi

  log_info "Configuring systemd units for container compatibility..."
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/multi-user.target.wants/* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/etc/systemd/system/*.wants/* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/local-fs.target.wants/* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/sockets.target.wants/*udev* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/sockets.target.wants/*initctl* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/basic.target.wants/* 2>/dev/null || true
  if [[ -d "$ROOTFS_DIR/lib/systemd/system/sysinit.target.wants" ]]; then
    (cd "$ROOTFS_DIR/lib/systemd/system/sysinit.target.wants" && for f in *; do [[ "$f" != "systemd-tmpfiles-setup.service" ]] && rm -f "$f"; done) 2>/dev/null || true
  fi

  # Enable SSH service if openssh-server was installed
  if [ -f "$ROOTFS_DIR/lib/systemd/system/ssh.service" ]; then
    log_info "Enabling ssh.service in multi-user.target.wants..."
    s mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
    s ln -sf /lib/systemd/system/ssh.service "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"
  fi

  log_info "Configuring official remote Astra Linux APT repositories in /etc/apt/sources.list..."
  cat << EOF_OFFICIAL_APT | s tee "$ROOTFS_DIR/etc/apt/sources.list" >/dev/null
deb https://download.astralinux.ru/astra/stable/${DETECTED_CODENAME}/repository-main/ ${DETECTED_CODENAME} main contrib non-free non-free-firmware
deb https://download.astralinux.ru/astra/stable/${DETECTED_CODENAME}/repository-extended/ ${DETECTED_CODENAME} main contrib non-free non-free-firmware
EOF_OFFICIAL_APT

  log_step "Importing rootfs into Docker -> ${FULL_IMAGE_TAG}"
  s tar -C "$ROOTFS_DIR" -c . | docker import \
    -c "ENV container=docker" \
    -c "ENV LANG=ru_RU.UTF-8" \
    -c "ENV LC_ALL=ru_RU.UTF-8" \
    -c "STOPSIGNAL SIGRTMIN+3" \
    -c 'CMD ["/sbin/init"]' \
    - "${FULL_IMAGE_TAG}"

  # Determine internal exact version dynamically
  INTERNAL_VERSION=""
  if [ -f "$ROOTFS_DIR/etc/astra_version" ]; then
    INTERNAL_VERSION=$(cat "$ROOTFS_DIR/etc/astra_version" | tr -d ' \r\n')
  fi
  if [ -z "$INTERNAL_VERSION" ] && [ -f "$ROOTFS_DIR/etc/os-release" ]; then
    INTERNAL_VERSION=$(grep -E '^VERSION_ID=' "$ROOTFS_DIR/etc/os-release" | head -n1 | cut -d= -f2 | tr -d ' "\r\n')
  fi
  if [ -z "$INTERNAL_VERSION" ]; then
    INTERNAL_VERSION="$DETECTED_VERSION"
  fi

  if [[ "$INTERNAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    PATCH_VER="$INTERNAL_VERSION"
    MINOR_VER=$(echo "$INTERNAL_VERSION" | cut -d. -f1,2)
    MAJOR_VER="$MINOR_VER"
  elif [[ "$INTERNAL_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    PATCH_VER="$INTERNAL_VERSION"
    MINOR_VER="$INTERNAL_VERSION"
    MAJOR_VER="$INTERNAL_VERSION"
  else
    PATCH_VER="1.8.6"
    MINOR_VER="1.8"
    MAJOR_VER="1.8"
  fi

  log_info "Extracted release versions:"
  log_info "  -> Full Tag:  $tag"
  log_info "  -> Patch Ver: $PATCH_VER"
  log_info "  -> Minor Ver: $MINOR_VER"
  log_info "  -> Major Ver: $MAJOR_VER"

  declare -a ALL_EXTRA_TAGS=()
  [ -n "$PATCH_VER" ] && [ "$PATCH_VER" != "$tag" ] && ALL_EXTRA_TAGS+=("$PATCH_VER")
  [ -n "$MINOR_VER" ] && [ "$MINOR_VER" != "$PATCH_VER" ] && ALL_EXTRA_TAGS+=("$MINOR_VER")
  [ -n "$MAJOR_VER" ] && ALL_EXTRA_TAGS+=("$MAJOR_VER")

  for extra_tag in "${ALL_EXTRA_TAGS[@]}"; do
    ext_t="${extra_tag}-${PRESET_CHOICE}"
    
    log_exec "docker tag ${FULL_IMAGE_TAG} ${IMAGE_NAME}:${ext_t}"
    docker tag "${FULL_IMAGE_TAG}" "${IMAGE_NAME}:${ext_t}"
    log_exec "docker tag ${FULL_IMAGE_TAG} ${GHCR_IMAGE_NAME}:${ext_t}"
    docker tag "${FULL_IMAGE_TAG}" "${GHCR_IMAGE_NAME}:${ext_t}"

    # Default preset also gets unqualified version tags (e.g. runalsh/astra-iso-patch:1.8.6)
    if [ "$PRESET_CHOICE" = "server" ]; then
      docker tag "${FULL_IMAGE_TAG}" "${IMAGE_NAME}:${extra_tag}"
      docker tag "${FULL_IMAGE_TAG}" "${GHCR_IMAGE_NAME}:${extra_tag}"
    fi
  done
  docker tag "${FULL_IMAGE_TAG}" "${FULL_GHCR_TAG}"

  if [ "$TEST_VERSION" = "true" ]; then
    log_step "Validating generated Docker image"
    if TEST_VER=$(docker run --rm "${FULL_IMAGE_TAG}" cat /etc/astra_version 2>/dev/null || docker run --rm "${FULL_IMAGE_TAG}" cat /etc/os-release 2>/dev/null); then
      echo -e "${C_CYAN}------------------------------------------------------------${C_RESET}"
      echo -e "${C_BOLD}Container OS identification:${C_RESET}\n${C_YELLOW}${TEST_VER}${C_RESET}"
      echo -e "${C_CYAN}------------------------------------------------------------${C_RESET}"
    else
      log_warn "Container execution failed or architecture mismatch. Skipping."
    fi
  fi

  if [ "$PUSH_TO_DOCKERHUB" = "true" ]; then
    log_step "Pushing to Docker Hub: ${FULL_IMAGE_TAG}"
    docker push "${FULL_IMAGE_TAG}"
    for extra_tag in "${ALL_EXTRA_TAGS[@]}"; do
      docker push "${IMAGE_NAME}:${extra_tag}-${PRESET_CHOICE}"
      if [ "$PRESET_CHOICE" = "server" ]; then
        docker push "${IMAGE_NAME}:${extra_tag}"
      fi
    done
  fi

  if [ "$PUSH_TO_GHCR" = "true" ]; then
    log_step "Pushing to GHCR: ${FULL_GHCR_TAG}"
    docker push "${FULL_GHCR_TAG}"
    for extra_tag in "${ALL_EXTRA_TAGS[@]}"; do
      docker push "${GHCR_IMAGE_NAME}:${extra_tag}-${PRESET_CHOICE}"
      if [ "$PRESET_CHOICE" = "server" ]; then
        docker push "${GHCR_IMAGE_NAME}:${extra_tag}"
      fi
    done
  fi

  SUCCESS_TAGS+=("${FULL_IMAGE_TAG}")
  cleanup_run
  trap - EXIT
done

echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}BUILD SUMMARY REPORT${C_RESET}"
echo -e "Images successfully built: ${#SUCCESS_TAGS[@]}"
for t in "${SUCCESS_TAGS[@]}"; do
  echo -e "  - ${C_BOLD}${t}${C_RESET}"
done
echo -e "${C_BOLD}==============================================================================${C_RESET}"

if [ "${CLEANUP_DOCKER_IMAGES:-false}" = "true" ]; then
  log_info "Performing Docker cleanup..."
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^((ghcr\.io/)?runalsh/astra-iso-patch)(:|$)' | xargs -r docker rmi -f 2>/dev/null || true
fi
