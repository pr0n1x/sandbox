#!/usr/bin/env bash
set -eu

usage() { echo "usage: sandbox.sh [-i|--interactive] [-w|--workdir DIR] [-h|--home DIR] [-a|--app-home] /usr/bin/someapp [args...]" >&2; exit 2; }

# '+' stops parsing at the first non-option, so the app's own flags pass through untouched
OPTS=$(getopt -o +iw:h:a -l interactive,workdir:,home:,app-home -n sandbox.sh -- "$@") || usage
eval set -- "$OPTS"

NEW_SESSION="--new-session"   # -i: keep the terminal session (job control), like docker run -i
WORKDIR_ARGS=()               # -w DIR: rw-bind DIR at its real path and start the app there
BOX=""                        # -h DIR: sandbox home; default is the shared box ~/sandboxes$HOME
APP_HOME=""                   # -a: use a per-app box instead, ~/sandboxes/<binary path>
while true; do
  case "$1" in
    -i|--interactive) NEW_SESSION=""; shift ;;
    -w|--workdir)
      WD="$(realpath -e "$2")" || { echo "sandbox.sh: workdir not found: $2" >&2; exit 1; }
      WORKDIR_ARGS=(--bind "$WD" "$WD" --chdir "$WD"); shift 2 ;;
    -h|--home) BOX="$(realpath -m "$2")"; shift 2 ;;
    -a|--app-home) APP_HOME=1; shift ;;
    --) shift; break ;;
  esac
done

APP_NAME="${1:?usage: sandbox.sh [-i] [-w DIR] [-h DIR] /usr/bin/someapp [args...]}"; shift || true
APP="$(which "$APP_NAME" || true)"   # unlike `command -v`, always a disk file, even for builtin names
[ -n "$APP" ] || { echo "sandbox.sh: app not found: $APP_NAME" >&2; exit 1; }
case "$APP" in /*) ;; *) APP="$(realpath -e "$APP")" ;; esac   # e.g. ./local-app

# the sandbox "home": -h DIR as given; -a per-app ~/sandboxes/usr/bin/foo; default shared ~/sandboxes/home/user
if [ -z "$BOX" ]; then
  if [ -n "$APP_HOME" ]; then BOX="$HOME/sandboxes$APP"; else BOX="$HOME/sandboxes$HOME"; fi
fi
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
