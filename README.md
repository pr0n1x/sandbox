# sandbox

Run a GUI (or any) application inside strict boundaries using
[bubblewrap](https://github.com/containers/bubblewrap): separate namespaces,
no network, and a private home directory — without giving the app access to
the real `$HOME`. Useful for apps installed system-wide (e.g. from a `.deb`)
that you don't fully trust.

## What it does

`sandbox.sh` launches the app with:

- **Own user / PID / IPC / UTS / network namespaces** (`--unshare-all`) —
  the network namespace contains only loopback, so the app has no network
  access and can't see host interfaces.
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
sandbox.sh [-i|--interactive] [-w|--workdir DIR] [-h|--home DIR] [-a|--app-home] /usr/bin/someapp [args...]
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

The app name is resolved with `which`, so `sandbox.sh ping` and
`sandbox.sh /usr/bin/ping` run the same binary and (with `-a`) use the same
sandbox directory.

## Requirements

- `bubblewrap` (`apt install bubblewrap`)
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
- `ping` never works inside: `no_new_privs` strips its file capability, and a
  fresh netns disables unprivileged ICMP sockets. Test with `curl` instead.

## TODO

- **Networking**: add a `-n`/`--net` flag that gives the sandbox internet
  access while keeping a separate network namespace — run under
  `pasta --config-net` (from the `passt` package, rootless NAT as used by
  Podman) and switch bwrap to `--unshare-all --share-net` so it stays in the
  netns pasta created.
