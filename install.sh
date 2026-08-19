#!/usr/bin/env bash
#
# install-omasnap-distrobox.sh
#
# Builds omasnap inside an Arch Linux distrobox container and installs a host
# launcher that executes the container binary.
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
CONTAINER_NAME="${OMASNAP_CONTAINER:-omasnap-arch}"
ARCH_IMAGE="${OMASNAP_IMAGE:-archlinux:latest}"
OMASNAP_REPO="${OMASNAP_REPO:-https://github.com/tobi/omasnap.git}"
OMASNAP_SRC="${OMASNAP_SRC:-$HOME/projects/omasnap}"
LOCAL_PREFIX="${HOME}/.local"
BIN_DIR="${LOCAL_PREFIX}/bin"
LIBEXEC_DIR="${LOCAL_PREFIX}/libexec"
LAUNCHER="${BIN_DIR}/omasnap"

log() {
  printf '\033[1;32m==>\033[0m %s
' "$*"
}

warn() {
  printf '\033[1;33m[warn]\033[0m %s
' "$*" >&2
}

die() {
  printf '\033[1;31m[error]\033[0m %s
' "$*" >&2
  exit 1
}

# Quote a value for use as a POSIX shell literal in the generated launcher.
shell_quote() {
  local value=${1//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf '\033[1;31m[error]\033[0m Installation failed.
' >&2
  fi
  exit "$status"
}

trap cleanup EXIT

case "$CONTAINER_NAME" in
''|*[!A-Za-z0-9_.-]*)
  die "OMASNAP_CONTAINER must contain only letters, numbers, '.', '_' and '-'."
  ;;
esac

[ "$(id -u)" -ne 0 ] || die "Do not run this script as root."
[ -n "${HOME:-}" ] || die "HOME is not set."

# --------------------------------------------------------------------------
# Host prerequisites
# --------------------------------------------------------------------------
log "Checking host prerequisites"
[ -n "${WAYLAND_DISPLAY:-}" ] ||
  warn "WAYLAND_DISPLAY is unset; omasnap needs a Wayland session at runtime."

[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] ||
  warn "HYPRLAND_INSTANCE_SIGNATURE is unset; Hyprland IPC may not work."

command -v git >/dev/null 2>&1 ||
  die "git is required on the host."

command -v curl >/dev/null 2>&1 ||
  die "curl is required on the host."

command -v grim >/dev/null 2>&1 ||
  die "grim is required on the host."

command -v wl-copy >/dev/null 2>&1 ||
  die "wl-copy is required on the host."

command -v wl-paste >/dev/null 2>&1 ||
  die "wl-paste is required on the host."

command -v docker >/dev/null 2>&1 ||
  die "Docker was not found. Install Docker first."

docker info >/dev/null 2>&1 || die \
  "Docker is installed but unusable by this user. Check the daemon or Docker group membership."

export PATH="${BIN_DIR}:${PATH}"

# --------------------------------------------------------------------------
# Install distrobox
# --------------------------------------------------------------------------
if command -v distrobox >/dev/null 2>&1; then
  log "distrobox already installed: $(command -v distrobox)"
else
  log "Installing distrobox into ${LOCAL_PREFIX}"
  mkdir -p "$LOCAL_PREFIX"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    https://raw.githubusercontent.com/89luca89/distrobox/main/install \
    | sh -s -- --prefix "$LOCAL_PREFIX"
fi

hash -r 2>/dev/null || true
DISTROBOX_BIN="$(command -v distrobox || true)"
DISTROBOX_ENTER="$(command -v distrobox-enter || true)"

[ -n "$DISTROBOX_BIN" ] ||
  die "distrobox was not found after installation. Ensure ${BIN_DIR} is on PATH."

[ -n "$DISTROBOX_ENTER" ] ||
  die "distrobox-enter was not found after installation."

# --------------------------------------------------------------------------
# Create the Arch container
# --------------------------------------------------------------------------
if "$DISTROBOX_BIN" list 2>/dev/null | grep -Fqw -- "$CONTAINER_NAME"; then
  log "Container '${CONTAINER_NAME}' already exists."
else
  log "Creating Arch container '${CONTAINER_NAME}' from '${ARCH_IMAGE}'."
  "$DISTROBOX_BIN" create \
    --name "$CONTAINER_NAME" \
    --image "$ARCH_IMAGE" \
    --yes
fi

log "Initializing container."
"$DISTROBOX_BIN" enter "$CONTAINER_NAME" -- true
"$DISTROBOX_BIN" enter "$CONTAINER_NAME" -- test -f /etc/arch-release ||
  die "Container '${CONTAINER_NAME}' is not an Arch Linux container."

# --------------------------------------------------------------------------
# Install container dependencies
# --------------------------------------------------------------------------
log "Installing omasnap dependencies inside the container."
"$DISTROBOX_BIN" enter "$CONTAINER_NAME" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
command -v sudo >/dev/null 2>&1 ||
  { echo "sudo is required inside the container." >&2; exit 1; }

sudo pacman -Syu --noconfirm --needed \
  base-devel \
  cmake \
  ninja \
  pkgconf \
  qt6-base \
  layer-shell-qt \
  wayland \
  wayland-protocols \
  hyprland \
  grim \
  wl-clipboard \
  tesseract \
  tesseract-data-eng \
  tesseract-data-tha \
  git
CONTAINER_SCRIPT

# --------------------------------------------------------------------------
# Clone or update source
# --------------------------------------------------------------------------
log "Preparing omasnap source at '${OMASNAP_SRC}'."
if [ -e "$OMASNAP_SRC" ] && [ ! -d "$OMASNAP_SRC/.git" ]; then
  die "The source path exists but is not a Git repository: ${OMASNAP_SRC}"
fi

if [ -d "$OMASNAP_SRC/.git" ]; then
  log "Repository already exists; updating it."
  git -C "$OMASNAP_SRC" diff --quiet ||
    die "Source checkout has uncommitted changes: ${OMASNAP_SRC}"
  git -C "$OMASNAP_SRC" pull --ff-only ||
    die "Could not fast-forward source checkout: ${OMASNAP_SRC}"
else
  mkdir -p "$(dirname "$OMASNAP_SRC")"
  git clone \
    --depth 1 \
    "$OMASNAP_REPO" \
    "$OMASNAP_SRC"
fi

# --------------------------------------------------------------------------
# Build and install
# --------------------------------------------------------------------------
log "Building omasnap inside the Arch container."
"$DISTROBOX_BIN" enter "$CONTAINER_NAME" -- \
  env "OMASNAP_SRC=${OMASNAP_SRC}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
cd "$OMASNAP_SRC"
cmake \
  -S . \
  -B build \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build --parallel

# Optional smoke test. Some versions of omasnap do not provide this target.
if [ -x ./build/omasnap-smoke ]; then
  QT_QPA_PLATFORM=offscreen \
    ./build/omasnap-smoke /tmp/omasnap-smoke || true
fi
cmake --install build
CONTAINER_SCRIPT

# --------------------------------------------------------------------------
# Relocate binary inside the shared home directory
# --------------------------------------------------------------------------
log "Relocating the container binary."
"$DISTROBOX_BIN" enter "$CONTAINER_NAME" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
source_binary="$HOME/.local/bin/omasnap"
destination="$HOME/.local/libexec/omasnap"
mkdir -p "$HOME/.local/libexec"

if [ -f "$source_binary" ]; then
  magic="$(head -c 2 "$source_binary" || true)"
  # Move the installed binary, but do not move an existing shell launcher.
  case "$magic" in
  \#\!)
    ;;
  *)
    mv -f "$source_binary" "$destination"
    ;;
  esac
fi
CONTAINER_SCRIPT

"$DISTROBOX_BIN" enter "$CONTAINER_NAME" -- \
  test -x "$HOME/.local/libexec/omasnap" ||
  die "The container binary was not installed at ~/.local/libexec/omasnap."

# --------------------------------------------------------------------------
# Create host launcher
# --------------------------------------------------------------------------
log "Installing host launcher at '${LAUNCHER}'."
mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"
quoted_container=$(shell_quote "$CONTAINER_NAME")
quoted_bin=$(shell_quote "$LIBEXEC_DIR/omasnap")
quoted_enter=$(shell_quote "$DISTROBOX_ENTER")
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Runs the Arch-built omasnap binary inside the distrobox container.
CONTAINER=$quoted_container
BIN=$quoted_bin
ENTER=$quoted_enter
HIS="\${HYPRLAND_INSTANCE_SIGNATURE:-}"
RUNTIME="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"

was_running=0
if [ "\$(docker inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null)" = true ]; then
  was_running=1
fi

"\$ENTER" -n "\$CONTAINER" -- sh -s -- "\$HIS" "\$RUNTIME" "\$BIN" "\$@" <<'CONTAINER_LAUNCHER'
set -eu
HIS=\$1
RUNTIME=\$2
BIN=\$3
shift 3

if [ -n "\$HIS" ] && [ -S "/tmp/hypr/\$HIS/.socket.sock" ]; then
  mkdir -p "\$RUNTIME/hypr" 2>/dev/null || true
  target="\$RUNTIME/hypr/\$HIS"
  source="/tmp/hypr/\$HIS"
  if [ -d "\$target" ] && [ ! -L "\$target" ]; then
    if [ ! -e "\$target/.socket.sock" ]; then
      ln -s "\$source/.socket.sock" "\$target/.socket.sock" 2>/dev/null || true
    fi
  elif [ ! -e "\$target" ] && [ ! -L "\$target" ]; then
    ln -s "\$source" "\$target" 2>/dev/null || true
  fi
fi

exec "\$BIN" "\$@"
CONTAINER_LAUNCHER
status=\$?

if [ "\$was_running" -eq 0 ]; then
  docker stop "\$CONTAINER" >/dev/null 2>&1 || true
fi

exit "\$status"
EOF

chmod 0755 "$LAUNCHER"
hash -r 2>/dev/null || true

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------
log "Verifying installation."
if "$LAUNCHER" --version; then
  log "omasnap launcher works."
else
  die "omasnap --version failed. Check the container and build output."
fi

log "Runtime capture is not run automatically."
cat <<EOF

Done.
omasnap launcher:
  ${LAUNCHER}

Try:
  ${LAUNCHER} --help
  ${LAUNCHER}
  ${LAUNCHER} --capture-fullscreen --save

Suggested Hyprland binding:
  bind = \$mainMod SHIFT, S, exec, ${LAUNCHER}

Notes:
- The first launch after a reboot may have a short container startup delay.
- The container is named '${CONTAINER_NAME}'.
- Re-run this script to update and rebuild omasnap.
- Ensure ${BIN_DIR} is included in your PATH.
EOF
