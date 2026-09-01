#!/usr/bin/env bash
set -eu

usage() { echo "usage: sandbox.sh [-i|--interactive] [-w|--workdir DIR] [-h|--home DIR] [-a|--app-home] [-n|--net[IFACE]] [-6|--ipv6] /usr/bin/someapp [args...]" >&2; exit 2; }

help() {
  cat <<EOF
usage: sandbox.sh [options] /usr/bin/someapp [args...]

Run an app inside strict bubblewrap isolation: own namespaces, no network,
read-only system, a private home under ~/sandboxes, Wayland/GPU/sound passed
through. See README.md for details.

options:
  -i, --interactive   keep the terminal session for job control, like
                      'docker run -i' (drops bwrap's --new-session)
  -w, --workdir DIR   rw-bind DIR at its real path and start the app there
  -h, --home DIR      use DIR as the sandbox home
                      (default: the shared box ~/sandboxes\$HOME)
  -a, --app-home      per-app sandbox home instead: ~/sandboxes/<binary path>
  -n, --net[IFACE]    outbound networking via pasta (rootless NAT); the app
                      runs as fake root inside. With an attached IFACE
                      (-nenp39s0 / --net=enp39s0) traffic is pinned to that
                      interface, bypassing e.g. a WireGuard default route
  -6, --ipv6          with -n: also enable IPv6 (default is IPv4-only)
  -x, --x11           pass the X11 socket and auth cookie through, for
                      X11-only apps (weakens isolation: X clients can snoop
                      each other)
      --help          show this help
EOF
  exit 0
}

# '+' stops parsing at the first non-option, so the app's own flags pass through untouched
OPTS=$(getopt -o +iw:h:an::6x -l help,interactive,workdir:,home:,app-home,net::,ipv6,x11 -n sandbox.sh -- "$@") || usage
eval set -- "$OPTS"

NEW_SESSION="--new-session"   # -i: keep the terminal session (job control), like docker run -i
WORKDIR_ARGS=()               # -w DIR: rw-bind DIR at its real path and start the app there
BOX=""                        # -h DIR: sandbox home; default is the shared box ~/sandboxes$HOME
APP_HOME=""                   # -a: use a per-app box instead, ~/sandboxes/<binary path>
NET=""                        # -n: pasta attaches to the sandbox netns for outbound networking
NET_ARGS=()                   # -n: root mapping inside the sandbox userns
RESOLV_ARGS=()                # -n: DNS goes through pasta's forwarder
PASTA_IP=(-4)                 # -6: also enable IPv6 in the sandbox network; default IPv4-only
IPV6=""
OUT_IF=""                     # -nIFACE: mirror IFACE inside and pin pasta's sockets to it
X11=""                        # -x: pass the X11 socket through (weakens isolation)
DNS_FWD=169.254.1.1
FWD_ARGS=(--dns-forward "$DNS_FWD")
while true; do
  case "$1" in
    --help) help ;;
    -i|--interactive) NEW_SESSION=""; shift ;;
    -w|--workdir)
      WD="$(realpath -e "$2")" || { echo "sandbox.sh: workdir not found: $2" >&2; exit 1; }
      WORKDIR_ARGS=(--bind "$WD" "$WD" --chdir "$WD"); shift 2 ;;
    -h|--home) BOX="$(realpath -m "$2")"; shift 2 ;;
    -a|--app-home) APP_HOME=1; shift ;;
    -6|--ipv6) PASTA_IP=(); IPV6=1; shift ;;
    -x|--x11) X11=1; shift ;;
    # the optional IFACE must be attached: -nIFACE / --net=IFACE
    -n|--net) NET=1; OUT_IF="$2"; shift 2 ;;
    --) shift; break ;;
  esac
done

if [ -n "$NET" ]; then
  # --uid 0: pasta can only gain caps in the sandbox userns if its uid maps to
  # root there (its self-hardening blocks the join otherwise), so with -n the
  # app runs as (fake) root inside, like rootless podman/docker containers
  NET_ARGS=(--uid 0 --gid 0)
  # bind at the symlink target (e.g. systemd-resolved's stub under /run),
  # creating its directory; must come after the /etc bind or it gets buried
  RESOLV="$(realpath -m /etc/resolv.conf)"
  RESOLV_ARGS=(--perms 0755 --dir "${RESOLV%/*}" --ro-bind-data 9 "$RESOLV")
fi
X11_ARGS=()
if [ -n "$X11" ]; then
  DISP="${DISPLAY:-:0}"; DISP="${DISP#*:}"; DISP="${DISP%%.*}"   # ":1" or "host:1.0" -> "1"
  XSOCK="/tmp/.X11-unix/X$DISP"
  [ -S "$XSOCK" ] || { echo "sandbox.sh: no X11 socket at $XSOCK" >&2; exit 1; }
  X11_ARGS=(--ro-bind "$XSOCK" "$XSOCK" --setenv DISPLAY ":$DISP")
  # the X server wants the auth cookie; keep its env path valid inside
  [ -z "${XAUTHORITY:-}" ] || X11_ARGS+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY" --setenv XAUTHORITY "$XAUTHORITY")
fi
OUT_ARGS=()
if [ -n "$OUT_IF" ]; then
  ip link show dev "$OUT_IF" >/dev/null || { echo "sandbox.sh: no such interface: $OUT_IF" >&2; exit 1; }
  # SO_BINDTODEVICE pins pasta's host sockets to IFACE, so its traffic bypasses
  # e.g. a WireGuard fwmark default route and leaves through IFACE itself
  OUT_ARGS=(-i "$OUT_IF" --outbound-if4 "$OUT_IF")
  [ -z "$IPV6" ] || OUT_ARGS+=(--outbound-if6 "$OUT_IF")
  # pinned sockets can't reach a loopback resolver (systemd-resolved's
  # 127.0.0.53 stub, pasta's default --dns-host from /etc/resolv.conf), so
  # forward DNS to IFACE's own upstream servers instead — not the global list,
  # which may hold servers only reachable through the tunnel being bypassed.
  # --dns-host takes one server per IP version: first v4, and first v6 with -6
  if UPSTREAM="$(resolvectl dns "$OUT_IF" 2>/dev/null)"; then
    NS4=""; NS6=""
    for NS in ${UPSTREAM#*:}; do
      case "$NS" in
        *:*) [ -n "$NS6" ] || NS6="$NS" ;;
        *)   [ -n "$NS4" ] || NS4="$NS" ;;
      esac
    done
    if pasta --help 2>&1 | grep -q -- --dns-host; then
      [ -z "$NS4" ] || OUT_ARGS+=(--dns-host "$NS4")
      [ -z "$NS6" ] || [ -z "$IPV6" ] || OUT_ARGS+=(--dns-host "$NS6")
    elif [ -n "$NS4" ]; then
      # old pasta (< 2024_10_30, e.g. Ubuntu 24.04) can't retarget the
      # forwarder: skip it and point the sandbox resolv.conf straight at the
      # upstream server; --no-map-gw so a gateway-hosted DNS reaches the real
      # gateway instead of being remapped to the host
      DNS_FWD="$NS4"
      FWD_ARGS=(--no-map-gw --dns none)   # --dns none: no "Couldn't get any nameserver" noise
    fi
  fi
fi

[ $# -ge 1 ] || usage
APP_NAME="$1"; shift
APP="$(which "$APP_NAME" || true)"   # unlike `command -v`, always a disk file, even for builtin names
[ -n "$APP" ] || { echo "sandbox.sh: app not found: $APP_NAME" >&2; exit 1; }
case "$APP" in /*) ;; *) APP="$(realpath -e "$APP")" ;; esac   # e.g. ./local-app

# a snap's binary run directly (realpath /snap/foo/current/...): expose /snap
# and forbid nested user namespaces. Snap builds never run their own userns
# sandbox under snapd (AppArmor denies it), and e.g. the firefox snap segfaults
# in every content process when that path is reachable; with --disable-userns
# the app sees clone() fail and falls back cleanly, as under Flatpak
SNAP_ARGS=()
case "$APP" in /snap/*) SNAP_ARGS=(--ro-bind /snap /snap --unshare-user --disable-userns) ;; esac

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
  "${SNAP_ARGS[@]}"
  --ro-bind /etc /etc
  "${RESOLV_ARGS[@]}"
  --proc /proc
  --dev /dev
  --dev-bind /dev/dri /dev/dri
  --ro-bind /sys /sys
  --tmpfs /tmp
  "${X11_ARGS[@]}"
  --bind "$BOX" "$HOME"
  # system appearance (dark/light theme): host toolkit configs, read-only
  --ro-bind-try "$HOME/.config/kdeglobals" "$HOME/.config/kdeglobals"
  --ro-bind-try "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
  --ro-bind-try "$HOME/.config/gtk-4.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"
  --ro-bind-try "$HOME/.gtkrc-2.0" "$HOME/.gtkrc-2.0"
  --ro-bind-try "$HOME/.config/qt5ct" "$HOME/.config/qt5ct"
  --ro-bind-try "$HOME/.config/qt6ct" "$HOME/.config/qt6ct"
  --ro-bind-try "$HOME/.themes" "$HOME/.themes"
  --ro-bind-try "$HOME/.icons" "$HOME/.icons"
  # GTK on Wayland takes theme and titlebar-button layout from GSettings, which
  # override settings.ini; dconf reads its db by mmap, so no D-Bus is needed
  --ro-bind-try "$HOME/.config/dconf/user" "$HOME/.config/dconf/user"
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

pasta --config-net --quiet "${PASTA_IP[@]}" "${OUT_ARGS[@]}" "${FWD_ARGS[@]}" \
      --userns "/proc/$CHILD_PID/ns/user" --netns "/proc/$CHILD_PID/ns/net" ||
  { echo "sandbox.sh: pasta failed (is the passt package installed?)" >&2; kill -9 "$CHILD_PID" "$BWRAP_PID" 2>/dev/null; exit 1; }

# a fresh netns has net.ipv4.ping_group_range empty, and modern ping drops its
# file caps and only tries unprivileged ICMP datagram sockets, gated by that
# sysctl; /proc/sys/net follows the writer's netns, so no mount ns join needed.
# Only gid 0 is mapped in the sandbox userns, so "0 0" is the widest legal range
nsenter --preserve-credentials -U -n -t "$CHILD_PID" \
  sh -c 'echo 0 0 > /proc/sys/net/ipv4/ping_group_range' 2>/dev/null || true

echo >&"$BLOCK_FD"   # network is up; release the app
wait "$BWRAP_PID"
