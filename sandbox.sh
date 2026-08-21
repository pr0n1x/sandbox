#!/usr/bin/env bash
set -eu

usage() { echo "usage: sandbox.sh [-i|--interactive] [-w|--workdir DIR] /usr/bin/someapp [args...]" >&2; exit 2; }

# '+' stops parsing at the first non-option, so the app's own flags pass through untouched
OPTS=$(getopt -o +iw: -l interactive,workdir: -n sandbox.sh -- "$@") || usage
eval set -- "$OPTS"

NEW_SESSION="--new-session"   # -i: keep the terminal session (job control), like docker run -i
WORKDIR_ARGS=()               # -w DIR: rw-bind DIR at its real path and start the app there
while true; do
  case "$1" in
    -i|--interactive) NEW_SESSION=""; shift ;;
    -w|--workdir)
      WD="$(realpath -e "$2")" || { echo "sandbox.sh: workdir not found: $2" >&2; exit 1; }
      WORKDIR_ARGS=(--bind "$WD" "$WD" --chdir "$WD"); shift 2 ;;
    --) shift; break ;;
  esac
done

APP="${1:?usage: sandbox.sh [-i] /usr/bin/someapp [args...]}"; shift || true
APP="$(command -v "$APP")" || { echo "sandbox.sh: app not found: $1" >&2; exit 1; }
BOX="$HOME/sandboxes$APP"   # /usr/bin/foo -> ~/sandboxes/usr/bin/foo; the app's entire "home" lives here
mkdir -p "$BOX"

WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

exec bwrap \
  --unshare-all \
  --die-with-parent \
  $NEW_SESSION \
  --hostname sandbox \
  --ro-bind /usr /usr \
  --symlink usr/bin /bin --symlink usr/sbin /sbin \
  --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --ro-bind-try /opt /opt \
  --ro-bind /etc /etc \
  --proc /proc \
  --dev /dev \
  --dev-bind /dev/dri /dev/dri \
  --ro-bind /sys /sys \
  --tmpfs /tmp \
  --bind "$BOX" "$HOME" \
  "${WORKDIR_ARGS[@]}" \
  --perms 0700 --dir "$XDG_RUNTIME_DIR" \
  --ro-bind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" \
  --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY" \
  --ro-bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0" \
  --ro-bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse" \
  --unsetenv DBUS_SESSION_BUS_ADDRESS \
  "$APP" "$@"

