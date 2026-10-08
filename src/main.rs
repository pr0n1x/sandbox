//! sandbox: run an app inside strict bubblewrap isolation — own namespaces,
//! no network unless asked, a per-box home, and an optional writable system
//! layer. See README.md.

mod boxdir;
mod cli;
mod net;
mod util;

use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use util::{die, home, output, realpath_e, realpath_m, warn, which};

/// Unmount the layers this run mounted, whichever way main() ends.
struct Cleanup(Vec<PathBuf>);
impl Drop for Cleanup {
    fn drop(&mut self) {
        boxdir::unmount(&self.0);
    }
}

fn main() {
    let opts = match cli::parse(std::env::args().skip(1).collect()) {
        Ok(o) => o,
        Err(e) => {
            e.report();
            std::process::exit(e.exit_status_code())
        }
    };
    let home = home();
    let mut args: Vec<OsString> = Vec::new();
    let push =
        |args: &mut Vec<OsString>, items: &[&str]| args.extend(items.iter().map(OsString::from));

    // -w/-W/-r at their real paths, the symlink as given recreated inside
    let mut bind_args: Vec<OsString> = Vec::new();
    for b in &opts.binds {
        bind_args.extend([
            if b.ro { "--ro-bind" } else { "--bind" }.into(),
            b.real.clone().into(),
            b.real.clone().into(),
        ]);
        if let Some(from) = &b.symlink_from {
            bind_args.extend([
                "--symlink".into(),
                b.real.clone().into(),
                from.clone().into(),
            ]);
        }
    }
    if let Some(cd) = opts.chdir.clone().or(opts.workdir.clone()) {
        bind_args.extend(["--chdir".into(), cd.into()]);
    }

    // --root, or -n: map the real uid to 0 inside. With -n it's required:
    // pasta can only gain caps in the sandbox userns if its uid maps to root
    // there (its self-hardening blocks the join otherwise) — like rootless
    // podman/docker
    let mut net_args: Vec<OsString> = Vec::new();
    if opts.root || opts.net {
        push(&mut net_args, &["--uid", "0", "--gid", "0"]);
    }
    // -n: the pipes bwrap gets, and the sandbox resolv.conf — its contents
    // come through one of them — bound at the symlink target (e.g.
    // systemd-resolved's stub under /run), creating its directory; must come
    // after the /etc bind or it gets buried
    let pipes = opts.net.then(net::Pipes::new);
    let mut resolv_args: Vec<OsString> = Vec::new();
    if let Some(p) = &pipes {
        let resolv = realpath_m(Path::new("/etc/resolv.conf"));
        let dir = resolv.parent().unwrap_or(Path::new("/")).to_path_buf();
        resolv_args.extend([
            "--perms".into(),
            "0755".into(),
            "--dir".into(),
            dir.into(),
            "--ro-bind-data".into(),
            p.resolv.read.as_raw_fd().to_string().into(),
            resolv.into(),
        ]);
    }

    // -x: the X11 socket and auth cookie; DISPLAY ":1" or "host:1.0" -> "1"
    let mut x11_args: Vec<OsString> = Vec::new();
    if opts.x11 {
        let display = std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into());
        let num = display.split_once(':').map(|(_, d)| d).unwrap_or(&display);
        let num = num.split('.').next().unwrap_or(num);
        let sock = PathBuf::from(format!("/tmp/.X11-unix/X{num}"));
        if !fs::metadata(&sock)
            .map(|m| m.file_type().is_socket())
            .unwrap_or(false)
        {
            die(1, format!("no X11 socket at {}", sock.display()));
        }
        x11_args.extend([
            "--ro-bind".into(),
            sock.clone().into(),
            sock.into(),
            "--setenv".into(),
            "DISPLAY".into(),
            format!(":{num}").into(),
        ]);
        if let Some(auth) = std::env::var_os("XAUTHORITY") {
            x11_args.extend([
                "--ro-bind".into(),
                auth.clone(),
                auth.clone(),
                "--setenv".into(),
                "XAUTHORITY".into(),
                auth,
            ]);
        }
    }

    // -p camera: --dev gives a minimal /dev with no video nodes, so bind each
    // V4L2 device (and the media controller nodes some drivers pair with them)
    let mut camera_args: Vec<OsString> = Vec::new();
    if opts.camera {
        if let Ok(rd) = fs::read_dir("/dev") {
            let mut devs: Vec<PathBuf> = rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    let n = p
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    (n.starts_with("video") || n.starts_with("media"))
                        && fs::metadata(p)
                            .map(|m| m.file_type().is_char_device())
                            .unwrap_or(false)
                })
                .collect();
            devs.sort();
            for d in devs {
                camera_args.extend(["--dev-bind".into(), d.clone().into(), d.into()]);
            }
        }
        if camera_args.is_empty() {
            warn("-p camera: no /dev/video* devices found");
        }
    }

    let netconf = if opts.net {
        Some(net::configure(opts.out_if.as_deref(), opts.ipv6))
    } else {
        None
    };

    // the app: resolved like `which` does, so `sandbox ping` and
    // `sandbox /usr/bin/ping` run the same binary and (with -a) share a box
    let (app, app_args): (Option<PathBuf>, Vec<String>) = match opts.cmd.split_first() {
        Some((name, rest)) => {
            let p = which(name).unwrap_or_else(|| die(1, format!("app not found: {name}")));
            let p = if p.is_absolute() {
                p
            } else {
                realpath_e(&p).unwrap_or(p)
            };
            (Some(p), rest.to_vec())
        }
        None => (None, Vec::new()),
    };

    // a snap's binary run directly (realpath /snap/foo/current/...): expose
    // /snap and forbid nested user namespaces. Snap builds never run their own
    // userns sandbox under snapd (AppArmor denies it), and e.g. the firefox
    // snap segfaults in every content process when that path is reachable;
    // with --disable-userns the app sees clone() fail and falls back cleanly,
    // as under Flatpak. --disable-userns works by nesting a second userns,
    // whose parent owns the netns — pasta can't control that from inside the
    // nested ns, so with -n forbid userns creation via sysctl instead (net.rs)
    let mut snap = false;
    let mut snap_args: Vec<OsString> = Vec::new();
    if let Some(rest) = app
        .as_ref()
        .and_then(|a| a.to_str())
        .and_then(|a| a.strip_prefix("/snap/"))
    {
        snap = true;
        // launcher scripts exec "$SNAP/...", which snapd normally provides. The
        // name vars matter too: e.g. firefox keys per-install profile selection
        // on them — without SNAP_INSTANCE_NAME it hashes its versioned
        // /snap/<name>/<rev> path as the install identity and orphans the
        // profile on every snap refresh
        let mut parts = rest.splitn(3, '/');
        let name = parts.next().unwrap_or("");
        let rev = parts.next().unwrap_or("");
        push(
            &mut snap_args,
            &[
                "--ro-bind",
                "/snap",
                "/snap",
                "--setenv",
                "SNAP",
                &format!("/snap/{name}/{rev}"),
                "--setenv",
                "SNAP_NAME",
                name,
                "--setenv",
                "SNAP_INSTANCE_NAME",
                name,
            ],
        );
        if !opts.net {
            push(&mut snap_args, &["--unshare-user", "--disable-userns"]);
        }
    }

    // -n maps the real uid to 0 (for pasta), which would leave the app running
    // as root with every user-owned file shown as root:root. Undo that for the
    // app itself unless --root asks for root: nest a second userns mapping 0
    // back to the real uid/gid, so ownership looks normal again (like podman
    // unshare in reverse). Ubuntu's userns restriction strips capabilities
    // from the creator (the app can't write its own uid_map), so the app just
    // waits for the mapping while we write it from outside — joining/holding
    // a userns isn't gated, only creating one. Snaps keep the fake root: their
    // nested userns is forbidden
    let app_wrap: Vec<String> = if opts.net && !snap && !opts.root {
        vec![
            "unshare".into(), "-U".into(), "sh".into(), "-c".into(),
            "n=0; while [ \"$(id -u)\" = 65534 ]; do [ \"$((n+=1))\" -lt 100 ] || { echo 'sandbox: no uid map after 5s' >&2; exit 1; }; sleep 0.05; done; exec \"$0\" \"$@\"".into(),
        ]
    } else {
        Vec::new()
    };

    // mirror the binary's file capabilities (e.g. ping's cap_net_raw=ep), which
    // no_new_privs would silently drop at exec, as ambient caps in the sandbox userns
    let mut cap_args: Vec<OsString> = Vec::new();
    if let Some(a) = &app {
        if let Some(out) = output("getcap", &[&a.to_string_lossy()]) {
            let caps = out.split_whitespace().last().unwrap_or("");
            let caps = caps.split(['=', '+']).next().unwrap_or("");
            if caps.starts_with("cap_") {
                for c in caps.split(',') {
                    cap_args.extend(["--cap-add".into(), c.to_uppercase().into()]);
                }
            }
        }
    }

    let bx = boxdir::resolve(opts.box_.as_deref(), opts.app_box, app.as_deref(), &home);
    if opts.reset {
        boxdir::reset_system(&bx);
        if app.is_none() {
            return;
        }
    }
    let app = app.expect("an app to run");

    let layer = if boxdir::has_layer(&bx) || opts.root {
        boxdir::mount_layer(&bx, opts.root)
    } else {
        boxdir::plain()
    };
    let cleanup = Cleanup(layer.mounts.clone());
    let shim_args = if opts.root {
        boxdir::shim_args(&bx)
    } else {
        Vec::new()
    };

    let runtime = PathBuf::from(
        std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_else(|| die(1, "XDG_RUNTIME_DIR is not set")),
    );
    let wayland = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".into());
    let h = |rel: &str| home.join(rel).into_os_string();

    push(&mut args, &["--unshare-all"]);
    args.extend(net_args);
    args.extend(cap_args);
    push(&mut args, &["--die-with-parent"]);
    if !opts.interactive {
        push(&mut args, &["--new-session"]);
    }
    push(&mut args, &["--hostname", "sandbox"]);
    args.extend(layer.args.iter().cloned());
    push(
        &mut args,
        &[
            "--symlink",
            "usr/bin",
            "/bin",
            "--symlink",
            "usr/sbin",
            "/sbin",
            "--symlink",
            "usr/lib",
            "/lib",
            "--symlink",
            "usr/lib64",
            "/lib64",
        ],
    );
    args.extend(snap_args);
    args.extend(resolv_args);
    push(
        &mut args,
        &[
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--dev-bind",
            "/dev/dri",
            "/dev/dri",
        ],
    );
    args.extend(camera_args);
    push(&mut args, &["--ro-bind", "/sys", "/sys", "--tmpfs", "/tmp"]);
    args.extend(x11_args);
    args.extend([
        "--bind".into(),
        bx.home.clone().into_os_string(),
        home.clone().into_os_string(),
    ]);
    // system appearance (dark/light theme): host toolkit configs, read-only.
    // GTK on Wayland takes theme and titlebar-button layout from GSettings,
    // which override settings.ini; dconf reads its db by mmap, so no D-Bus
    for rel in [
        ".config/kdeglobals",
        ".config/gtk-3.0/settings.ini",
        ".config/gtk-4.0/settings.ini",
        ".gtkrc-2.0",
        ".config/qt5ct",
        ".config/qt6ct",
        ".themes",
        ".icons",
        ".config/dconf/user",
    ] {
        args.extend(["--ro-bind-try".into(), h(rel), h(rel)]);
    }
    args.extend(bind_args);
    args.extend(shim_args.clone());
    args.extend([
        "--perms".into(),
        "0700".into(),
        "--dir".into(),
        runtime.clone().into_os_string(),
    ]);
    let wl = runtime.join(&wayland);
    args.extend([
        "--ro-bind".into(),
        wl.clone().into_os_string(),
        wl.into_os_string(),
        "--setenv".into(),
        "WAYLAND_DISPLAY".into(),
        wayland.into(),
    ]);
    for s in ["pipewire-0", "pulse"] {
        let p = runtime.join(s);
        args.extend([
            "--ro-bind-try".into(),
            p.clone().into_os_string(),
            p.into_os_string(),
        ]);
    }
    // gtk3-nocsd forces server-side titlebars onto every GTK app via env; the
    // preload works inside too (/usr is bound) and silently overrides the
    // app's own decoration setting (e.g. firefox's titlebar checkbox): strip
    // it. --root prepends the shim
    push(
        &mut args,
        &[
            "--unsetenv",
            "GTK_CSD",
            "--unsetenv",
            "DBUS_SESSION_BUS_ADDRESS",
        ],
    );
    let host_preload = std::env::var("LD_PRELOAD").ok();
    let mut preload: Vec<String> = host_preload
        .iter()
        .flat_map(|s| s.split(':'))
        .filter(|l| !l.is_empty() && !l.contains("nocsd"))
        .map(str::to_string)
        .collect();
    if !shim_args.is_empty() {
        preload.insert(0, boxdir::SHIM_INSIDE.into());
    }
    if !preload.is_empty() {
        push(&mut args, &["--setenv", "LD_PRELOAD", &preload.join(":")]);
    } else if host_preload.is_some() {
        push(&mut args, &["--unsetenv", "LD_PRELOAD"]);
    }

    let code = match netconf {
        None => {
            if cleanup.0.is_empty() {
                // nothing to clean up afterwards: become bwrap
                let err = Command::new("bwrap")
                    .args(&args)
                    .arg(&app)
                    .args(&app_args)
                    .exec();
                die(1, format!("cannot run bwrap: {err}"))
            }
            let mut child = Command::new("bwrap")
                .args(&args)
                .arg(&app)
                .args(&app_args)
                .spawn()
                .unwrap_or_else(|e| die(1, format!("cannot run bwrap: {e}")));
            net::forward_signals_to(&child);
            net::exit_code(
                child
                    .wait()
                    .unwrap_or_else(|e| die(1, format!("waiting for bwrap: {e}"))),
            )
        }
        Some(n) => net::run(
            &args,
            &app_wrap,
            &app,
            &app_args,
            &n,
            snap,
            pipes.expect("pipes exist with -n"),
        ),
    };
    drop(cleanup);
    std::process::exit(code);
}
