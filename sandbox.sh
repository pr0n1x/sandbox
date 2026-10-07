#!/usr/bin/env bash
set -eu

usage() { echo "usage: sandbox.sh [-i|--interactive] [-w|--bind DIR]... [-W|--workdir DIR]... [-r|--ro-bind DIR]... [-d|--chdir DIR] [-b|--box NAME|DIR] [-a|--app-box] [-n|--net[IFACE]] [-6|--ipv6] [-x|--x11] [-p|--permissions LIST]... [--root] /usr/bin/someapp [args...]\n       sandbox.sh [-b NAME|DIR] --reset-system" >&2; exit 2; }

help() {
  cat <<EOF
usage: sandbox.sh [options] /usr/bin/someapp [args...]
       sandbox.sh [-b NAME|DIR] --reset-system

Run an app inside strict bubblewrap isolation: own namespaces, no network,
read-only system, a private home, Wayland/GPU/sound passed through.
Everything the app keeps lives in its box, ~/sandboxes/<name>/, laid out
like the root filesystem:
  home/$USER              bound as \$HOME
  usr/ etc/ opt/ var/     the app's changes to the system, once a --root
                          run created them (fuse-overlayfs layers over
                          the host's dirs; a box without them sees the
                          host's system read-only)
See README.md for details.

options:
  -i, --interactive   keep the terminal session for job control, like
                      'docker run -i' (drops bwrap's --new-session)
  -w, --bind DIR      rw-bind DIR at its real path; repeatable
  -W, --workdir DIR   rw-bind DIR at its real path and start the app there
                      (in the last one if repeated)
  -r, --ro-bind DIR   ro-bind DIR at its real path; repeatable
  -d, --chdir DIR     start the app in DIR (overrides -W's chdir)
  -b, --box NAME|DIR  use box ~/sandboxes/NAME, or the directory DIR
                      (default: the shared box ~/sandboxes/default)
  -a, --app-box       per-app box instead, named after the binary's path:
                      /usr/bin/foo -> ~/sandboxes/usr-bin-foo
  -n, --net[IFACE]    outbound networking via pasta (rootless NAT); snap
                      apps run as fake root inside. With an attached IFACE
                      (-nenp39s0 / --net=enp39s0) traffic is pinned to that
                      interface, bypassing e.g. a WireGuard default route
  -6, --ipv6          with -n: also enable IPv6 (default is IPv4-only)
  -x, --x11           pass the X11 socket and auth cookie through, for
                      X11-only apps (weakens isolation: X clients can snoop
                      each other)
  -p, --permissions LIST
                      grant extra access to host resources, comma-separated;
                      repeatable. Known permissions:
                        camera   the webcam(s): /dev/video* and /dev/media*
                        x11      same as -x
  --root              run as root inside: uid 0 in the sandbox is your own
                      uid outside, so it grants no host privileges; files it
                      creates are yours. Gives the box a system layer (/usr,
                      /etc, /opt, /var writable, changes kept in the box,
                      never reaching the host) that shows every system file
                      as root's, so installers can change anything readable;
                      e.g. 'sandbox --root -b mybox dpkg -i x.deb'
  --reset-system      reset the box's system to the host's, keeping its
                      home: removes the system layer (usr/ etc/ opt/ var/
                      and the overlay's scratch dirs). Refused while a
                      sandbox has the box mounted
  -h, --help          show this help
EOF
  exit 0
}

# '+' stops parsing at the first non-option, so the app's own flags pass through untouched
OPTS=$(getopt -o +iw:W:r:d:hb:an::6xp: -l help,interactive,bind:,workdir:,ro-bind:,chdir:,box:,app-box,net::,ipv6,x11,permissions:,root,reset-system -n sandbox.sh -- "$@") || usage
eval set -- "$OPTS"

# -w/-W/-r DIR: bind DIR's real path ($1: --bind/--ro-bind); a symlink DIR is
# also recreated inside the sandbox, so the path as given keeps working
bind_dir() {
  BOUND="$(realpath -e "$2")" || { echo "sandbox.sh: bind dir not found: $2" >&2; exit 1; }
  BIND_ARGS+=("$1" "$BOUND" "$BOUND")
  local ORIG; ORIG="$(realpath -se "$2")"   # absolute, but symlinks unresolved
  [ "$ORIG" = "$BOUND" ] || BIND_ARGS+=(--symlink "$BOUND" "$ORIG")
}

NEW_SESSION="--new-session"   # -i: keep the terminal session (job control), like docker run -i
BIND_ARGS=()                  # -w/-W/-r DIR (repeatable): rw-/ro-bind DIR at its real path
WD=""                         # the last -W DIR: chdir there
CD=""                         # --chdir DIR: start the app there (overrides -W's chdir)
BOX=""                        # -b NAME|DIR: the box, ~/sandboxes/NAME or DIR; default ~/sandboxes/default
APP_BOX=""                    # -a: use a per-app box instead, ~/sandboxes/usr-bin-foo
NET=""                        # -n: pasta attaches to the sandbox netns for outbound networking
NET_ARGS=()                   # -n: root mapping inside the sandbox userns
RESOLV_ARGS=()                # -n: DNS goes through pasta's forwarder
PASTA_IP=(-4)                 # -6: also enable IPv6 in the sandbox network; default IPv4-only
IPV6=""
OUT_IF=""                     # -nIFACE: mirror IFACE inside and pin pasta's sockets to it
X11=""                        # -x: pass the X11 socket through (weakens isolation)
CAMERA=""                     # -p camera: pass /dev/video* (V4L2 webcams) through
LAYER=""                      # set below if the box has a system layer (or --root creates one)
ROOT=""                       # --root: uid 0 inside (mapped to the real uid), no un-rooting
CLEAR=""                      # --reset-system: drop the box's system layer, keep its home
DNS_FWD=169.254.1.1
FWD_ARGS=(--dns-forward "$DNS_FWD")
while true; do
  case "$1" in
    -h|--help) help ;;
    -i|--interactive) NEW_SESSION=""; shift ;;
    -w|--bind) bind_dir --bind "$2"; shift 2 ;;
    -W|--workdir) bind_dir --bind "$2"; WD="$BOUND"; shift 2 ;;
    -r|--ro-bind) bind_dir --ro-bind "$2"; shift 2 ;;
    -d|--chdir) CD="$(realpath -m "$2")"; shift 2 ;;
    -b|--box) BOX="$2"; shift 2 ;;
    -a|--app-box) APP_BOX=1; shift ;;
    -6|--ipv6) PASTA_IP=(); IPV6=1; shift ;;
    -x|--x11) X11=1; shift ;;
    # -p NAME[,NAME...]: named grants of host resources, so new ones don't
    # each need an option letter
    -p|--permissions)
      IFS=, read -ra PERMS <<<"$2"
      for PERM in "${PERMS[@]}"; do
        case "$PERM" in
          camera) CAMERA=1 ;;
          x11) X11=1 ;;
          '') ;;
          *) echo "sandbox.sh: unknown permission: $PERM (known: camera, x11)" >&2; exit 2 ;;
        esac
      done; shift 2 ;;
    # the optional IFACE must be attached: -nIFACE / --net=IFACE
    -n|--net) NET=1; OUT_IF="$2"; shift 2 ;;
    --root) ROOT=1; shift ;;
    --reset-system) CLEAR=1; shift ;;
    --) shift; break ;;
  esac
done
CD="${CD:-$WD}"
[ -z "$CD" ] || BIND_ARGS+=(--chdir "$CD")

# --root, or -n: map the real uid to 0 inside. With -n it's required: pasta can
# only gain caps in the sandbox userns if its uid maps to root there (its
# self-hardening blocks the join otherwise) — like rootless podman/docker
[ -z "$ROOT" ] && [ -z "$NET" ] || NET_ARGS=(--uid 0 --gid 0)
if [ -n "$NET" ]; then
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
# -p camera: --dev gives a minimal /dev with no video nodes, so bind each V4L2
# device (and the media controller nodes some drivers pair with them) into it
CAMERA_ARGS=()
if [ -n "$CAMERA" ]; then
  for DEV in /dev/video* /dev/media*; do
    [ -c "$DEV" ] && CAMERA_ARGS+=(--dev-bind "$DEV" "$DEV")
  done
  [ ${#CAMERA_ARGS[@]} -gt 0 ] || echo "sandbox.sh: -p camera: no /dev/video* devices found" >&2
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

[ $# -ge 1 ] || [ -n "$CLEAR" ] || usage
APP=""
if [ $# -ge 1 ]; then   # (--reset-system alone has no app to run)
  APP_NAME="$1"; shift
  APP="$(which "$APP_NAME" || true)"   # unlike `command -v`, always a disk file, even for builtin names
  [ -n "$APP" ] || { echo "sandbox.sh: app not found: $APP_NAME" >&2; exit 1; }
  case "$APP" in /*) ;; *) APP="$(realpath -e "$APP")" ;; esac   # e.g. ./local-app
fi

# a snap's binary run directly (realpath /snap/foo/current/...): expose /snap
# and forbid nested user namespaces. Snap builds never run their own userns
# sandbox under snapd (AppArmor denies it), and e.g. the firefox snap segfaults
# in every content process when that path is reachable; with --disable-userns
# the app sees clone() fail and falls back cleanly, as under Flatpak.
# --disable-userns works by nesting a second userns, whose parent owns the
# netns — pasta can't control that from inside the nested ns, so with -n
# forbid userns creation via sysctl instead, written from outside below
SNAP=""
SNAP_ARGS=()
case "$APP" in /snap/*)
  SNAP=1
  # launcher scripts exec "$SNAP/...", which snapd normally provides. The
  # name vars matter too: e.g. firefox keys per-install profile selection on
  # them — without SNAP_INSTANCE_NAME it hashes its versioned /snap/<name>/<rev>
  # path as the install identity and orphans the profile on every snap refresh
  SNAPNAME="${APP#/snap/}"; SNAPREST="${SNAPNAME#*/}"; SNAPNAME="${SNAPNAME%%/*}"
  SNAPDIR="/snap/$SNAPNAME/${SNAPREST%%/*}"
  SNAP_ARGS=(--ro-bind /snap /snap --setenv SNAP "$SNAPDIR"
             --setenv SNAP_NAME "$SNAPNAME" --setenv SNAP_INSTANCE_NAME "$SNAPNAME")
  [ -n "$NET" ] || SNAP_ARGS+=(--unshare-user --disable-userns) ;;
esac

# -n maps the real uid to 0 (for pasta, see above), which would leave the app
# running as root with every user-owned file shown as root:root. Undo that for
# the app itself unless --root asks for root: nest a second userns mapping 0 back
# to the real uid/gid, so ownership looks normal again (like podman unshare in
# reverse). Ubuntu's
# userns restriction strips capabilities from the creator (the app can't
# write its own uid_map), so the app just waits for the mapping while
# sandbox.sh writes it from outside — joining/holding a userns isn't gated,
# only creating one. Snaps keep the fake root: their nested userns is
# forbidden. Raw-socket caps don't survive into the nested ns, but the ping
# sysctl below still applies (gid 1000 inner = gid 0 outer, still in range)
APP_WRAP=()
[ -z "$NET" ] || [ -n "$SNAP" ] || [ -n "$ROOT" ] || APP_WRAP=(unshare -U sh -c
  'n=0; while [ "$(id -u)" = 65534 ]; do
     [ "$((n+=1))" -lt 100 ] || { echo "sandbox.sh: no uid map after 5s" >&2; exit 1; }
     sleep 0.05
   done; exec "$0" "$@"')

# mirror the binary's file capabilities (e.g. ping's cap_net_raw=ep), which
# no_new_privs would silently drop at exec, as ambient caps in the sandbox userns
CAP_ARGS=()
CAPS="$(getcap "$APP" 2>/dev/null)"; CAPS="${CAPS##* }"; CAPS="${CAPS%%[=+]*}"
if [[ "$CAPS" == cap_* ]]; then
  IFS=, read -ra CAP_LIST <<<"$CAPS"
  for CAP in "${CAP_LIST[@]}"; do CAP_ARGS+=(--cap-add "${CAP^^}"); done
fi

# the box holds everything the app keeps, laid out like /: <box>$HOME is
# bound as the sandbox $HOME, <box>/usr etc. take the system writes.
# -b: a bare NAME is a box under ~/sandboxes, anything with a slash is a
# directory; -a: per-app box named after the binary's path with dashes for
# slashes (/usr/bin/foo -> usr-bin-foo); default: the shared box
# ~/sandboxes/default
if [ -z "$BOX" ]; then
  if [ -n "$APP_BOX" ]; then
    [ -n "$APP" ] || { echo "sandbox.sh: -a needs an app to name the box after" >&2; exit 2; }
    APP_SLUG="${APP#/}"; BOX="$HOME/sandboxes/${APP_SLUG//\//-}"
  else BOX="$HOME/sandboxes/default"; fi
elif [[ "$BOX" != */* ]]; then BOX="$HOME/sandboxes/$BOX"
else BOX="$(realpath -m "$BOX")"
fi
BOX_HOME="$BOX$HOME"
mkdir -p "$BOX_HOME"

# --reset-system: back to the host's system, home untouched. Not while the
# layers are mounted (a sandbox is running on the box): the daemons would
# keep serving from directories we pulled away under them
if [ -n "$CLEAR" ]; then
  ! grep -q " $BOX/.mnt/" /proc/mounts ||
    { echo "sandbox.sh: $BOX is in use (its layers are mounted); stop its sandboxes first" >&2; exit 1; }
  chmod -R u+rwX "$BOX/.work" 2>/dev/null || true   # overlay scratch dirs can be mode 000
  rm -rf "$BOX"/{usr,etc,opt,var,.work,.mnt}
  echo "sandbox.sh: system of $BOX reset to the host's; its home is untouched" >&2
  [ -n "$APP" ] || exit 0
fi

# A box has a system layer once a --root run created it (<box>/usr etc.
# exist); every start of that box then uses it, nothing to remember on the
# launcher. The system dirs become fuse-overlayfs mounts — host dir as the read-only
# lower layer, <box>/DIR as the writable upper, scratch space in <box>/.work —
# so the app sees a writable system while the host never changes. The mounts
# are made here on the host side, by this user through the setuid
# fusermount3 like any sshfs, and bound into the sandbox: no capability is
# needed inside, so Ubuntu's bwrap profile (which denies the children all
# capabilities) stays as it is; kernel overlayfs would need the mount done by
# bwrap and then can't write anything owned by an unmapped uid. --root adds
# squash_to_uid: every file reports your uid, which the sandbox shows as
# root, so an installer can edit, chown and replace whatever it can read
# (root-only host files stay out of reach: nothing unprivileged reads them).
# Both views use fuse-overlayfs' xattr_permissions: the mode an app asks
# for is recorded in an xattr while the real file stays accessible to the
# daemon — which has no capabilities, so a real mode-000 file (dpkg creates
# its temp files that way) would be unreadable to it and break lookups in
# its directory. The record also holds the owner, which is what gives the
# plain view normal semantics: inside, root and you are the same uid, so
# without bookkeeping a file an installer creates would look like the app's
# own, writable. Only the plain view uses xattr_permissions (the --root
# view can't: it would make the daemon deny fake root wherever no record
# says otherwise), so what --root runs install, like what is dropped into
# the box from outside, carries no record — and before the plain view is
# mounted everything unrecorded is labeled root's (0:0, real mode kept).
# Installed files are thus read-only system files for the app, like on the
# host; what the app creates gets a record of its own and stays its.
# The --root view in turn needs rootshim.so (see rootshim.c, built with
# make): neither fake root nor the daemon has capabilities, so a directory
# created with mode 000 — dpkg does that, chmodding later — can't be opened
# by the daemon to finish the mkdir. The shim keeps the owner's bits.
# A mount already present (another sandbox on this box, in the same mode:
# the squashed and the plain view live under .mnt/root and .mnt/user) is
# reused, not remounted; only mounts made here are unmounted at exit,
# lazily, so a sandbox still using one keeps it alive
LAYER_ARGS=()
FUSE_MNTS=()
cleanup() {
  local M
  for M in "${FUSE_MNTS[@]}"; do fusermount3 -u -z "$M" 2>/dev/null || true; done
  [ -z "${TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT
OWNER_XATTR=user.containers.override_stat   # fuse-overlayfs' record (xattr_permissions=2): "uid:gid:mode"
# before a plain mount: label everything unrecorded root's, real mode kept
mark_root() {
  local STAMP="$BOX/.work/marked" F NEWER=()
  mkdir -p "$BOX/.work"
  [ ! -e "$STAMP" ] || NEWER=(-newercm "$STAMP")   # only what changed since the last pass
  find "$BOX/usr" "$BOX/etc" "$BOX/opt" "$BOX/var" \( -type f -o -type d \) "${NEWER[@]}" -print0 2>/dev/null |
    while IFS= read -r -d '' F; do
      getfattr -n "$OWNER_XATTR" --only-values -- "$F" >/dev/null 2>&1 ||
        setfattr -n "$OWNER_XATTR" -v "0:0:$(printf '%o' "0x$(stat -c %f -- "$F")")" -- "$F" 2>/dev/null || true
    done
  : > "$STAMP"
}
layer() {
  local DIR="$1" MODE=user OPTS MNT
  [ -z "$ROOT" ] || MODE=root
  MNT="$BOX/.mnt/$MODE$DIR"
  [ -d "$DIR" ] || return 0
  mkdir -p "$MNT" "$BOX$DIR" "$BOX/.work$DIR"
  if ! mountpoint -q "$MNT"; then
    OPTS="lowerdir=$DIR,upperdir=$BOX$DIR,workdir=$BOX/.work$DIR"
    if [ -n "$ROOT" ]
    then OPTS="$OPTS,squash_to_uid=$(id -u),squash_to_gid=$(id -g)"
    else OPTS="$OPTS,xattr_permissions=2"
    fi
    fuse-overlayfs -o "$OPTS" "$MNT" || { echo "sandbox.sh: fuse-overlayfs failed to mount $DIR" >&2; exit 1; }
    FUSE_MNTS+=("$MNT")
  fi
  LAYER_ARGS+=(--bind "$MNT" "$DIR")
}
for DIR in usr etc opt var; do [ ! -d "$BOX/$DIR" ] || LAYER=1; done
[ -z "$ROOT" ] || LAYER=1
if [ -n "$LAYER" ]; then
  command -v fuse-overlayfs >/dev/null ||
    { echo "sandbox.sh: this box has a system layer, which needs fuse-overlayfs (apt install fuse-overlayfs)" >&2; exit 1; }
  # /var only exists in the sandbox with a layer: package managers need it.
  # dpkg's and apt's lock files are root-only on the host, so they can't be
  # copied up to be opened for writing; shadow them with empty box files
  for F in var/lib/dpkg/lock var/lib/dpkg/lock-frontend var/lib/dpkg/triggers/Lock var/lib/apt/lists/lock var/cache/apt/archives/lock; do
    [ -e "/$F" ] && [ ! -r "/$F" ] && [ ! -e "$BOX/$F" ] && { mkdir -p "$BOX/${F%/*}"; : > "$BOX/$F"; }
  done
  [ -n "$ROOT" ] || mark_root
  for DIR in /usr /etc /opt /var; do layer "$DIR"; done
else
  LAYER_ARGS=(--ro-bind /usr /usr --ro-bind-try /opt /opt --ro-bind /etc /etc)
fi
# --root: preload rootshim.so (built next to this script, see above)
SHIM_ARGS=()
SHIM=""
if [ -n "$ROOT" ]; then
  SHIM="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/rootshim.so"
  if [ -f "$SHIM" ]; then
    # bound inside /usr (a path AppArmor lets every program read libraries
    # from); the mountpoint file is created here with a normal mode, so the
    # empty file it leaves in the box can be labeled like the rest
    mkdir -p "$BOX/usr/lib"; [ -e "$BOX/usr/lib/sandbox-rootshim.so" ] || : > "$BOX/usr/lib/sandbox-rootshim.so"
    SHIM_ARGS=(--ro-bind "$SHIM" /usr/lib/sandbox-rootshim.so)
  else echo "sandbox.sh: --root without rootshim.so (run make in ${SHIM%/*}): installers that create mode-000 dirs, like dpkg, will fail" >&2; SHIM=""
  fi
fi

WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

BWRAP_ARGS=(
  --unshare-all
  "${NET_ARGS[@]}"
  "${CAP_ARGS[@]}"
  --die-with-parent
  $NEW_SESSION
  --hostname sandbox
  "${LAYER_ARGS[@]}"
  --symlink usr/bin /bin --symlink usr/sbin /sbin
  --symlink usr/lib /lib --symlink usr/lib64 /lib64
  "${SNAP_ARGS[@]}"
  "${RESOLV_ARGS[@]}"
  --proc /proc
  --dev /dev
  --dev-bind /dev/dri /dev/dri
  "${CAMERA_ARGS[@]}"
  --ro-bind /sys /sys
  --tmpfs /tmp
  "${X11_ARGS[@]}"
  --bind "$BOX_HOME" "$HOME"
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
  "${BIND_ARGS[@]}"
  "${SHIM_ARGS[@]}"
  --perms 0700 --dir "$XDG_RUNTIME_DIR"
  --ro-bind "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
  --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
  --ro-bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0"
  --ro-bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse"
  # gtk3-nocsd forces server-side titlebars onto every GTK app via env; the
  # preload works inside too (/usr is bound) and silently overrides the app's
  # own decoration setting (e.g. firefox's titlebar checkbox), so strip it
  --unsetenv GTK_CSD
  --unsetenv DBUS_SESSION_BUS_ADDRESS
)
PRELOAD=""
for LIB in ${LD_PRELOAD:+${LD_PRELOAD//:/ }}; do
  case "$LIB" in *nocsd*) ;; *) PRELOAD="$PRELOAD:$LIB" ;; esac
done
[ -z "$SHIM" ] || PRELOAD=":/usr/lib/sandbox-rootshim.so$PRELOAD"
if [ -n "${PRELOAD#:}" ]
then BWRAP_ARGS+=(--setenv LD_PRELOAD "${PRELOAD#:}")
elif [ -n "${LD_PRELOAD:-}" ]
then BWRAP_ARGS+=(--unsetenv LD_PRELOAD)
fi

if [ -z "$NET" ]; then
  # exec unless there are layer mounts to clean up afterwards
  [ ${#FUSE_MNTS[@]} -gt 0 ] || exec bwrap "${BWRAP_ARGS[@]}" "$APP" "$@"
  bwrap "${BWRAP_ARGS[@]}" "$APP" "$@"; exit
fi

# -n: bwrap creates the namespaces (its AppArmor profile allows userns); pasta
# only *attaches* to the sandbox netns via setns(), which the Ubuntu userns
# restriction doesn't gate — so pasta needs no profile of its own. The app is
# held on --block-fd until pasta has configured the network.
TMP="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/sandbox.XXXXXX")"   # removed by cleanup (trap above)
mkfifo "$TMP/status" "$TMP/block"
exec {STATUS_FD}<>"$TMP/status" {BLOCK_FD}<>"$TMP/block"   # rw so opens never block

bwrap --json-status-fd "$STATUS_FD" --block-fd "$BLOCK_FD" "${BWRAP_ARGS[@]}" \
  "${APP_WRAP[@]}" "$APP" "$@" 9<<<"nameserver $DNS_FWD" &
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
# Only gid 0 is mapped in the sandbox userns, so "0 0" is the widest legal range.
# For snaps, zero max_user_namespaces: the app holds no caps and can't gain
# any under no_new_privs, so it cannot raise the limit back
SYSCTLS='echo 0 0 > /proc/sys/net/ipv4/ping_group_range'
[ -z "$SNAP" ] || SYSCTLS="$SYSCTLS; echo 0 > /proc/sys/user/max_user_namespaces"
nsenter --preserve-credentials -U -n -t "$CHILD_PID" sh -c "$SYSCTLS" 2>/dev/null || true

OUTER_NS="$(readlink "/proc/$CHILD_PID/ns/user")"
echo >&"$BLOCK_FD"   # network is up; release the app

# the released app (see APP_WRAP) now unshares its nested userns and waits;
# once that shows up, write the 0 -> real uid/gid mapping from here. The app
# is a child of bwrap's mini-init (CHILD_PID, still in the outer ns).
# nsenter into the outer ns first (via the init): the maps may only be
# written from the nested ns's parent userns, and the host is the
# grandparent. As the outer ns owns the nested one, joining it grants the
# needed caps, and a single line mapping one's own euid/egid is always allowed
if [ ${#APP_WRAP[@]} -gt 0 ]; then
  MAPPED=""
  for _ in $(seq 100); do
    [ -d "/proc/$CHILD_PID" ] || break   # app already gone
    APP_PID="$(awk '{print $1}' "/proc/$CHILD_PID/task/$CHILD_PID/children" 2>/dev/null)"
    if [ -n "$APP_PID" ] &&
       [ "$(readlink "/proc/$APP_PID/ns/user" 2>/dev/null)" != "$OUTER_NS" ]; then
      nsenter --preserve-credentials -U -t "$CHILD_PID" sh -c \
        "echo deny > /proc/$APP_PID/setgroups
         echo '$(id -g) 0 1' > /proc/$APP_PID/gid_map
         echo '$(id -u) 0 1' > /proc/$APP_PID/uid_map" && MAPPED=1
      break
    fi
    sleep 0.05
  done
  [ -n "$MAPPED" ] ||
    echo "sandbox.sh: setting the app's uid map failed; it runs as nobody" >&2
fi
wait "$BWRAP_PID"
