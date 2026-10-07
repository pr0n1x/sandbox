# sandbox

Run a GUI (or any) application inside strict boundaries using
[bubblewrap](https://github.com/containers/bubblewrap): separate namespaces,
no network, and a private home directory — without giving the app access to
the real `$HOME`. Useful for apps installed system-wide (e.g. from a `.deb`)
that you don't fully trust.

## What it does

`sandbox.sh` launches the app with:

- **Own user / PID / IPC / UTS / network namespaces** (`--unshare-all`) —
  the network namespace contains only loopback, so by default the app has no
  network access and can't see host interfaces. `-n` grants outbound internet
  through [pasta](https://passt.top/) while keeping the separate netns.
- **A box per sandbox**: everything the app keeps lives in one directory,
  `~/sandboxes/<name>/` — by default the shared box `~/sandboxes/default`,
  or a per-app / named box via `-a` / `-b`. The box is laid out like the
  root filesystem:
  - `home/<user>` (the real home path under the box, e.g.
    `~/sandboxes/default/home/user`) is bind-mounted as the app's `$HOME`;
    the real home directory is invisible.
  - `usr/`, `etc/`, `opt/`, `var/` hold the app's changes to the system
    when run with `-l` (see below). (`.work/` is the overlay's scratch
    space, `.mnt/` where the layered views are mounted while a sandbox runs:
    `.mnt/user/` the plain view, `.mnt/root/` the `--root` one.)
- **Read-only system**: `/usr`, `/etc`, `/opt`, `/sys` are bound read-only;
  `/tmp` is a fresh tmpfs. With `-l` the first three (and `/var`) become
  writable fuse-overlayfs layers instead: the app can change "the system",
  but the changes land in the box and the host stays untouched.
- **Wayland GUI, GPU and sound**: the Wayland socket, `/dev/dri` and
  PipeWire/PulseAudio sockets are passed through. D-Bus is deliberately not.
  The webcam is not either, unless granted with `-p camera`.
- **System appearance**: the host's theme configs (`~/.config/kdeglobals`,
  GTK `settings.ini`, `qt5ct`/`qt6ct`, `~/.themes`, `~/.icons`, and the
  dconf database `~/.config/dconf/user`) are bound read-only into the box
  home, so Qt/GTK apps follow the host dark/light theme. The dconf db
  matters on Wayland: GTK takes the theme and the titlebar-button layout
  (KDE syncs both into GSettings) from there, overriding `settings.ini` —
  without it Firefox draws GNOME's `menu:close` buttons in Adwaita. Apps that only listen to the desktop portal (libadwaita, Electron)
  won't pick it up — that would need the D-Bus session bus.
- **No terminal control** by default (`--new-session`).
- **Snap binaries** (app path under `/snap`, e.g.
  `` sandbox "$(realpath /snap/firefox/current/usr/lib/firefox/firefox)" ``):
  `/snap` is bound read-only and nested user namespaces are forbidden
  (`--disable-userns`). Run outside snapd, the binary uses the host's libs;
  the userns ban makes apps whose snap build crashes on its own
  namespace sandbox (Firefox: every content process segfaults) fall back
  cleanly, as under Flatpak.

## Usage

```sh
sandbox.sh [-i|--interactive] [-w|--bind DIR]... [-W|--workdir DIR]... [-r|--ro-bind DIR]... [-d|--chdir DIR] [-b|--box NAME|DIR] [-a|--app-box] [-n|--net[IFACE]] [-6|--ipv6] [-x|--x11] [-p|--permissions LIST]... [-l|--layer] [--root] /usr/bin/someapp [args...]
sandbox.sh [options] --install PKG.deb... [dpkg options]
```

- `-i`, `--interactive` — drop `--new-session` so an interactive shell inside
  the sandbox gets job control (like `docker run -i`). Only safe when the
  kernel has `dev.tty.legacy_tiocsti = 0` (default on modern kernels), which
  blocks the TIOCSTI terminal-injection attack `--new-session` guards against.
- `-w DIR`, `--bind DIR` — bind DIR read-write at its real path inside the
  sandbox; repeatable. This is the way to hand the app a specific
  project/data directory while the rest of `$HOME` stays hidden.
  A symlink DIR is dereferenced: its target is bound at the target's path and
  the symlink itself is recreated inside the sandbox, so the path as given
  keeps working (same for `-W`/`-r`).
- `-W DIR`, `--workdir DIR` — like `-w`, and also start the app there (like
  `docker run -w`); if repeated, the app starts in the last one.
- `-r DIR`, `--ro-bind DIR` — like `-w`, but read-only; repeatable.
- `-d DIR`, `--chdir DIR` — start the app in DIR, overriding `-W`'s chdir.
- `-b NAME|DIR`, `--box NAME|DIR` — the box to use (created if missing): a
  bare NAME means `~/sandboxes/NAME`, anything containing a slash is taken
  as a directory. Overrides `-a`.
- `-a`, `--app-box` — use a per-app box named after the binary's path, with
  dashes for slashes (`/usr/bin/foo` → `~/sandboxes/usr-bin-foo`), instead
  of the default shared box `~/sandboxes/default` that all apps see together.
- `-n[IFACE]`, `--net[=IFACE]` — outbound internet access, still in a separate network
  namespace: bwrap creates the namespaces as usual, then `pasta` (rootless
  user-mode NAT, as used by Podman) *attaches* to the sandbox netns and relays
  TCP/UDP through unprivileged host sockets; the app is held on bwrap's
  `--block-fd` until the network is configured. Because pasta only joins an
  existing namespace instead of creating one, it needs no AppArmor userns
  profile of its own. DNS goes through pasta's `--dns-forward` to the host's
  real resolver, so systemd-resolved and VPN/split-DNS setups keep working.
  With `-n` the sandbox userns maps the real uid to root — pasta's
  self-hardening only lets it gain the needed capabilities there when its uid
  maps to root. The app itself still runs under the real uid: it is nested
  into a second userns mapping root back, so files keep their normal
  ownership (without this everything the user owns shows as `root:root`).
  Ubuntu's userns restriction strips the sandboxed app of the capabilities
  needed to write its own uid map, so sandbox.sh writes the map from outside,
  from the parent (sandbox) userns — joining one isn't gated, only creating.
  Exception: snap apps keep the fake root, since their nested userns is
  deliberately forbidden (see above).
  Requires the `passt` package. TCP/UDP (curl, browsers) work out
  of the box; `ping` replies additionally need unprivileged ping sockets
  enabled on the host — see the ICMP note in Notes below.
- `-6`, `--ipv6` — with `-n`, also enable IPv6 in the sandbox network; the
  default is IPv4-only (pasta `-4`). On hosts with IPv6 disabled, pasta then
  prints `No routable interface for IPv6` and falls back to IPv4.
- `-x`, `--x11` — pass the X11 socket for `$DISPLAY` (and the `$XAUTHORITY`
  cookie) through, for X11-only apps such as Qt builds without the Wayland
  plugin. Weakens isolation: X11 clients can snoop each other's windows and
  input.
  The optional IFACE (must be attached: `-nenp39s0` or `--net=enp39s0`)
  mirrors that interface inside the sandbox (pasta `-i`) and pins pasta's
  host sockets to it (`--outbound-if4`, via `SO_BINDTODEVICE`). Bound sockets
  bypass policy routing, so sandbox traffic goes straight out of IFACE even
  when a WireGuard tunnel with `AllowedIPs 0.0.0.0/0` owns the host's default
  route — the sandbox gets the physical uplink while the host stays on the
  VPN. Caveat: DNS is forwarded to the host resolver (systemd-resolved),
  whose own upstream queries still follow host routing.
- `-p LIST`, `--permissions LIST` — grant the app extra access to host
  resources that are withheld by default; comma-separated, repeatable
  (`-p camera` or `-p camera,foo`). Unknown names are rejected. Known
  permissions:
  - `camera` — the webcam(s): every `/dev/video*` (V4L2) and `/dev/media*`
    node is bound into the sandbox's otherwise minimal `/dev`. Without the
    D-Bus session bus there is no camera portal, so apps must use V4L2
    directly (Firefox and Chromium do).
  - `x11` — same as `-x`.
- `-l`, `--layer` — writable system through a persistent layer: `/usr`,
  `/etc`, `/opt` and `/var` (which is otherwise absent) are mounted with
  [fuse-overlayfs](https://github.com/containers/fuse-overlayfs), the host
  dirs as the read-only lower layer and the box's `usr/`, `etc/`, `opt/`,
  `var/` as the writable upper layer. Changes the app makes to the system
  land in the box and never reach the host; the box holds exactly the diff,
  and wiping those dirs resets the system. The mounts are made on the host
  side, by you, through the setuid `fusermount3` like any sshfs — under
  `<box>/.mnt/` — and bound into the sandbox, so nothing inside needs a
  capability and Ubuntu's stock bwrap profile stays untouched. A sandbox
  started while another one already has the box's layers mounted in the
  same mode (plain or `--root`) reuses them; the mounts go away (lazily)
  when the sandbox that made them exits. A `--root` sandbox next to a
  running plain one gets its own mounts over the same box: fine for an
  install, but the running app sees the result only after a restart.
  Without `--root` the app sees the system as on the host: root's files —
  the host's and those installed into the box under `--root` — are
  read-only; the app can create files where a normal user could (its home,
  world-writable dirs) and keeps full access to what it created itself.
  Inside the sandbox root and you are the same uid, so this needs
  bookkeeping. Both views are mounted with fuse-overlayfs'
  `xattr_permissions`: the owner and mode an app sets are recorded in an
  xattr and reported from it, while the real file stays readable to the
  daemon (which has no capabilities; a real mode-000 file, as dpkg creates
  its temp files, would otherwise break every lookup in its directory). The
  record is `user.containers.override_stat`. Only the plain view records
  (the `--root` view can't use that mode: it would make the daemon deny
  fake root wherever no record says otherwise), so what `--root` runs
  install, like what is dropped into the box from outside, carries no
  record — and before a plain view is mounted, sandbox.sh labels
  everything unrecorded root's (`0:0`, real mode kept). What the app
  creates gets a record of its own and stays the app's. A `--root` run
  concurrent with a plain one is seen by the running app as the app's own
  files until the app's next start. Needs the `fuse-overlayfs` package.
- `--root` — run the app as root inside the sandbox: uid 0 there is your
  own uid outside, so it grants no host privileges, and files it creates
  are yours on disk. For installers and other `id -u`-checking tools.
  Implies `-l`, and the layers are then mounted with `squash_to_uid`: every
  system file reports your uid, which the sandbox shows as root, so an
  installer can edit, replace, hard-link and chown-to-root anything it can
  read — `dpkg -i`, `apt-get install ./pkg.deb`, vendor `install.sh`
  scripts work, maintainer scripts included, and `/var/lib/dpkg` is the
  host's database with the box's changes layered on top. Limits: host files
  only root can read (`/etc/shadow`, other users' data) stay unreadable and
  so can't be copied up or replaced — nothing unprivileged can change that;
  and `chown` to any uid but your own fails with EINVAL, since the sandbox
  maps a single uid (packages shipping files owned by `_apt`, `man` etc.
  need `--force-...`-style workarounds or a fix-up). dpkg's and apt's lock
  files are root-only on the host, so the box gets empty shadows of them.
  Anything a package installs shadows the host's version from then on, host
  upgrades included (e.g. `ld.so.cache` after a postinst runs `ldconfig`).
  `--root` runs preload `rootshim.so` (build it once with `make`; without
  it `--root` warns): neither fake root nor the FUSE daemon has
  capabilities, so a directory created with mode 000 — dpkg does that for
  every directory, chmodding later — can't be opened by the daemon to
  finish the mkdir; the shim keeps the owner's bits in every mode an
  installer sets (`rwx` on directories, `rw` on files; see `rootshim.c`).
  Statically linked programs and ones AppArmor confines separately (Ubuntu
  ships a profile for `who`, which prints a harmless "cannot be preloaded"
  when a postinst calls it) run without it. No short option on purpose.
  Under `-n` the app is normally un-rooted after pasta's root mapping;
  `--root` keeps the root.

The app name is resolved with `which`, so `sandbox.sh ping` and
`sandbox.sh /usr/bin/ping` run the same binary and (with `-a`) use the same
box.

## Requirements

- `bubblewrap` (`apt install bubblewrap`)
- `passt` (`apt install passt`) — only for `-n`/`--net`. No AppArmor setup
  needed: pasta only attaches to the netns bwrap already created, and joining
  an existing namespace isn't gated by the Ubuntu userns restriction.
- `fuse-overlayfs` (`apt install fuse-overlayfs`) — only for `-l`/`--root`.
- a C compiler and `make` to build `rootshim.so` — only for `--root`.
- On Ubuntu 24.04+ unprivileged user namespaces are restricted by AppArmor.
  The `apparmor` package ships `/etc/apparmor.d/bwrap-userns-restrict`,
  which lets bwrap create them and confines everything it starts to a
  profile with no capabilities at all. The sandbox is designed to live with
  that: nothing inside ever needs a capability (the layer mounts are made
  on the host side). Don't add an unconfined `bwrap` profile of your own —
  a profile of the same name is loaded alphabetically after yours anyway,
  so it would silently lose.

## Notes

- X11-only apps (symptom: `could not connect to display`, `Available
  platform plugins are: xcb`) need `-x`.
- Electron/Chromium apps may need their own `--no-sandbox` flag; the outer
  sandbox is still provided by bwrap.
- The app binary's file capabilities (e.g. ping's `cap_net_raw=ep`), which
  `no_new_privs` would otherwise drop at exec, are mirrored into the sandbox
  as ambient capabilities — they apply only inside the sandbox's own
  namespaces. Note that without `-n`'s root mapping, Ubuntu's userns
  hardening still blocks some uses of them (e.g. raw sockets).
- A persistent writable `/usr` (`-l`) means a compromised app can plant
  binaries that run on its next start: the layer is part of the sandbox's
  trust domain, like the home. Files under `<box>/usr` etc. carry
  `user.containers.override_stat` xattrs (recorded owner and mode, see
  `-l`) and possibly fuse-overlayfs whiteout markers; `ls -l` shows them as
  a `+`. Edit the box from outside only while no sandbox has it mounted;
  files you drop in become root's in the plain view at the next start.
- `ping` under `-n` sends packets (via the mirrored `CAP_NET_RAW`), but
  replies only come back if the host allows unprivileged ping sockets, which
  pasta uses to relay ICMP:

  ```sh
  echo 'net.ipv4.ping_group_range = 0 2147483647' | sudo tee /etc/sysctl.d/99-sandboxed-ping.conf
  sudo sysctl --system
  ```

  Without that (or without `-n` at all) `ping` fails — test connectivity with
  `curl` instead.

## Launcher icons

`sandbox-icon.sh` badges an app icon with a `#` mark so a sandboxed launcher
is distinguishable from the real one (there is no way to overlay an icon from
a `.desktop` file itself — the `Icon=` key only takes a name or a path):

```sh
sandbox-icon.sh firefox                        # icon name from the theme
sandbox-icon.sh -o max-sandboxed /usr/share/pixmaps/max.png
```

It composites the badge onto the icon (PNG or SVG, name or path), installs
the result at the usual sizes into `~/.local/share/icons/hicolor/` as
`<icon>-sandboxed` (or the `-o` name) and prints that name for the launcher's
`Icon=` line. Needs ImageMagick 7.
