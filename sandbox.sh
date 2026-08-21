#!/usr/bin/env bash
set -eu

usage() { echo "usage: sandbox.sh [-i|--interactive] [-w|--workdir DIR] [-h|--home DIR] [-a|--app-home] [-n|--net] /usr/bin/someapp [args...]" >&2; exit 2; }

# '+' stops parsing at the first non-option, so the app's own flags pass through untouched
OPTS=$(getopt -o +iw:h:an -l interactive,workdir:,home:,app-home,net -n sandbox.sh -- "$@") || usage
eval set -- "$OPTS"

NEW_SESSION="--new-session"   # -i: keep the terminal session (job control), like docker run -i
WORKDIR_ARGS=()               # -w DIR: rw-bind DIR at its real path and start the app there
BOX=""                        # -h DIR: sandbox home; default is the shared box ~/sandboxes$HOME
APP_HOME=""                   # -a: use a per-app box instead, ~/sandboxes/<binary path>
NET=""                        # -n: pasta attaches to the sandbox netns for outbound networking
NET_ARGS=()                   # -n: root mapping inside the sandbox userns
RESOLV_ARGS=()                # -n: DNS goes through pasta's forwarder
DNS_FWD=169.254.1.1
while true; do
  case "$1" in
    -i|--interactive) NEW_SESSION=""; shift ;;
    -w|--workdir)
      WD="$(realpath -e "$2")" || { echo "sandbox.sh: workdir not found: $2" >&2; exit 1; }
      WORKDIR_ARGS=(--bind "$WD" "$WD" --chdir "$WD"); shift 2 ;;
    -h|--home) BOX="$(realpath -m "$2")"; shift 2 ;;
    -a|--app-home) APP_HOME=1; shift ;;
    # --uid 0: pasta can only gain caps in the sandbox userns if its uid maps to
    # root there (its self-hardening blocks the join otherwise), so with -n the
    # app runs as (fake) root inside, like rootless podman/docker containers
    -n|--net)
      NET=1
      NET_ARGS=(--uid 0 --gid 0)
      # bind at the symlink target (e.g. systemd-resolved's stub under /run),
      # creating its directory; must come after the /etc bind or it gets buried
      RESOLV="$(realpath -m /etc/resolv.conf)"
      RESOLV_ARGS=(--perms 0755 --dir "${RESOLV%/*}" --ro-bind-data 9 "$RESOLV")
      shift ;;
    --) shift; break ;;
  esac
done

APP_NAME="${1:?usage: sandbox.sh [-i] [-w DIR] [-h DIR] /usr/bin/someapp [args...]}"; shift || true
APP="$(which "$APP_NAME" || true)"   # unlike `command -v`, always a disk file, even for builtin names
[ -n "$APP" ] || { echo "sandbox.sh: app not found: $APP_NAME" >&2; exit 1; }
case "$APP" in /*) ;; *) APP="$(realpath -e "$APP")" ;; esac   # e.g. ./local-app

# mirror the binary's file capabilities (e.g. ping's cap_net_raw=ep), which
# no_new_privs would silently drop at exec, as ambient caps in the sandbox userns
CAP_ARGS=()
CAPS="$(getcap "$APP" 2>/dev/null)"; CAPS="${CAPS##* }"; CAPS="${CAPS%%[=+]*}"
if [[ "$CAPS" == cap_* ]]; then
  IFS=, read -ra CAP_LIST <<<"$CAPS"
  for CAP in "${CAP_LIST[@]}"; do CAP_ARGS+=(--cap-add "${CAP^^}"); done
fi

# the sandbox "home": -h DIR as given; -a per-app ~/sandboxes/usr/bin/foo; default shared ~/sandboxes/home/user
if [ -z "$BOX" ]; then
  if [ -n "$APP_HOME" ]; then BOX="$HOME/sandboxes$APP"; else BOX="$HOME/sandboxes$HOME"; fi
fi
mkdir -p "$BOX"

WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

BWRAP_ARGS=(
  --unshare-all
  "${NET_ARGS[@]}"
  "${CAP_ARGS[@]}"
  --die-with-parent
  $NEW_SESSION
  --hostname sandbox
  --ro-bind /usr /usr
  --symlink usr/bin /bin --symlink usr/sbin /sbin
  --symlink usr/lib /lib --symlink usr/lib64 /lib64
  --ro-bind-try /opt /opt
  --ro-bind /etc /etc
  "${RESOLV_ARGS[@]}"
  --proc /proc
  --dev /dev
  --dev-bind /dev/dri /dev/dri
  --ro-bind /sys /sys
  --tmpfs /tmp
  --bind "$BOX" "$HOME"
  "${WORKDIR_ARGS[@]}"
  --perms 0700 --dir "$XDG_RUNTIME_DIR"
  --ro-bind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
  --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
  --ro-bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0"
  --ro-bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse"
  --unsetenv DBUS_SESSION_BUS_ADDRESS
)

[ -n "$NET" ] || exec bwrap "${BWRAP_ARGS[@]}" "$APP" "$@"

# -n: bwrap creates the namespaces (its AppArmor profile allows userns); pasta
# only *attaches* to the sandbox netns via setns(), which the Ubuntu userns
# restriction doesn't gate — so pasta needs no profile of its own. The app is
# held on --block-fd until pasta has configured the network.
TMP="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/sandbox.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkfifo "$TMP/status" "$TMP/block"
exec {STATUS_FD}<>"$TMP/status" {BLOCK_FD}<>"$TMP/block"   # rw so opens never block

bwrap --json-status-fd "$STATUS_FD" --block-fd "$BLOCK_FD" "${BWRAP_ARGS[@]}" \
  "$APP" "$@" 9<<<"nameserver $DNS_FWD" &
BWRAP_PID=$!

# first status message arrives once the namespaces exist; it also carries
# namespace inode numbers, so pick the child-pid field specifically
read -r -t 10 STATUS_LINE <&"$STATUS_FD" || STATUS_LINE=""
CHILD_PID="$(sed -n 's/.*"child-pid": *\([0-9][0-9]*\).*/\1/p' <<<"$STATUS_LINE")"
[ -n "$CHILD_PID" ] ||
  { echo "sandbox.sh: bwrap did not report a child pid" >&2; kill -9 "$BWRAP_PID" 2>/dev/null; exit 1; }

pasta --config-net --quiet --dns-forward "$DNS_FWD" \
      --userns "/proc/$CHILD_PID/ns/user" --netns "/proc/$CHILD_PID/ns/net" ||
  { echo "sandbox.sh: pasta failed (is the passt package installed?)" >&2; kill -9 "$CHILD_PID" "$BWRAP_PID" 2>/dev/null; exit 1; }

echo >&"$BLOCK_FD"   # network is up; release the app
wait "$BWRAP_PID"
