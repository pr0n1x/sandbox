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
- **Private home**: the app's `$HOME` is a bind mount of a sandbox dir —
  by default the shared box `~/sandboxes/<real-home-path>` (e.g.
  `~/sandboxes/home/user`), or a per-app / explicit box via `-a` / `-h`.
  The real home directory is invisible.
- **Read-only system**: `/usr`, `/etc`, `/opt`, `/sys` are bound read-only;
  `/tmp` is a fresh tmpfs.
- **Wayland GUI, GPU and sound**: the Wayland socket, `/dev/dri` and
  PipeWire/PulseAudio sockets are passed through. D-Bus is deliberately not.
- **No terminal control** by default (`--new-session`).

## Usage

```sh
sandbox.sh [-i|--interactive] [-w|--workdir DIR] [-h|--home DIR] [-a|--app-home] [-n|--net[IFACE]] [-6|--ipv6] /usr/bin/someapp [args...]
```

- `-i`, `--interactive` — drop `--new-session` so an interactive shell inside
  the sandbox gets job control (like `docker run -i`). Only safe when the
  kernel has `dev.tty.legacy_tiocsti = 0` (default on modern kernels), which
  blocks the TIOCSTI terminal-injection attack `--new-session` guards against.
- `-w DIR`, `--workdir DIR` — bind DIR read-write at its real path inside the
  sandbox and start the app there (like `docker run -w`). This is the way to
  hand the app a specific project/data directory while the rest of `$HOME`
  stays hidden.
- `-h DIR`, `--home DIR` — use DIR as the sandbox home (created if missing).
  Overrides `-a`.
- `-a`, `--app-home` — use a per-app box, `~/sandboxes/<full-path-of-binary>`
  (e.g. `/usr/bin/foo` → `~/sandboxes/usr/bin/foo`), instead of the default
  shared box `~/sandboxes/<real-home-path>` that all apps see together.
- `-n[IFACE]`, `--net[=IFACE]` — outbound internet access, still in a separate network
  namespace: bwrap creates the namespaces as usual, then `pasta` (rootless
  user-mode NAT, as used by Podman) *attaches* to the sandbox netns and relays
  TCP/UDP through unprivileged host sockets; the app is held on bwrap's
  `--block-fd` until the network is configured. Because pasta only joins an
  existing namespace instead of creating one, it needs no AppArmor userns
  profile of its own. DNS goes through pasta's `--dns-forward` to the host's
  real resolver, so systemd-resolved and VPN/split-DNS setups keep working.
  With `-n` the app runs as (fake) root inside its user namespace, like
  rootless podman/docker containers — pasta's self-hardening only lets it
  gain the needed capabilities in the sandbox userns when its uid maps to
  root there. Requires the `passt` package. TCP/UDP (curl, browsers) work out
  of the box; `ping` replies additionally need unprivileged ping sockets
  enabled on the host — see the ICMP note in Notes below.
- `-6`, `--ipv6` — with `-n`, also enable IPv6 in the sandbox network; the
  default is IPv4-only (pasta `-4`). On hosts with IPv6 disabled, pasta then
  prints `No routable interface for IPv6` and falls back to IPv4.
  The optional IFACE (must be attached: `-nenp39s0` or `--net=enp39s0`)
  mirrors that interface inside the sandbox (pasta `-i`) and pins pasta's
  host sockets to it (`--outbound-if4`, via `SO_BINDTODEVICE`). Bound sockets
  bypass policy routing, so sandbox traffic goes straight out of IFACE even
  when a WireGuard tunnel with `AllowedIPs 0.0.0.0/0` owns the host's default
  route — the sandbox gets the physical uplink while the host stays on the
  VPN. Caveat: DNS is forwarded to the host resolver (systemd-resolved),
  whose own upstream queries still follow host routing.

The app name is resolved with `which`, so `sandbox.sh ping` and
`sandbox.sh /usr/bin/ping` run the same binary and (with `-a`) use the same
sandbox directory.

## Requirements

- `bubblewrap` (`apt install bubblewrap`)
- `passt` (`apt install passt`) — only for `-n`/`--net`. No AppArmor setup
  needed: pasta only attaches to the netns bwrap already created, and joining
  an existing namespace isn't gated by the Ubuntu userns restriction.
- On Ubuntu 24.04+ unprivileged user namespaces are restricted by AppArmor;
  bwrap needs a profile allowing them:

  ```sh
  sudo tee /etc/apparmor.d/bwrap <<'EOF'
  abi <abi/4.0>,
  include <tunables/global>

  profile bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,
    include if exists <local/bwrap>
  }
  EOF
  sudo apparmor_parser -r /etc/apparmor.d/bwrap
  ```

## Notes

- X11-only apps need the X socket passed through (weakens isolation —
  X11 clients can snoop each other): add
  `--ro-bind /tmp/.X11-unix/X0 /tmp/.X11-unix/X0 --setenv DISPLAY :0`.
- Electron/Chromium apps may need their own `--no-sandbox` flag; the outer
  sandbox is still provided by bwrap.
- The app binary's file capabilities (e.g. ping's `cap_net_raw=ep`), which
  `no_new_privs` would otherwise drop at exec, are mirrored into the sandbox
  as ambient capabilities — they apply only inside the sandbox's own
  namespaces. Note that without `-n`'s root mapping, Ubuntu's userns
  hardening still blocks some uses of them (e.g. raw sockets).
- `ping` under `-n` sends packets (via the mirrored `CAP_NET_RAW`), but
  replies only come back if the host allows unprivileged ping sockets, which
  pasta uses to relay ICMP:

  ```sh
  echo 'net.ipv4.ping_group_range = 0 2147483647' | sudo tee /etc/sysctl.d/99-sandboxed-ping.conf
  sudo sysctl --system
  ```

  Without that (or without `-n` at all) `ping` fails — test connectivity with
  `curl` instead.
