//! Integration tests: the built binary runs real bwrap sandboxes on a
//! scratch box under `target/test-tmp`, with a throwaway `$HOME` and
//! runtime dir, so nothing touches the user's own boxes. Each test checks
//! what the app sees from inside (via `sh -c`) against what lands in the
//! box on disk. Tests whose host prerequisites are missing (user
//! namespaces, `/dev/dri`, pasta, fuse-overlayfs) skip themselves with a
//! note on stderr instead of failing.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const SANDBOX: &str = env!("CARGO_BIN_EXE_sandbox");

/// Skip the test, with the reason, when a host prerequisite is missing.
macro_rules! require {
    ($cond:expr, $why:expr) => {
        if !$cond {
            eprintln!("skipped: {}", $why);
            return;
        }
    };
}

/// A throwaway environment for one test: `home/` is `$HOME` (so even the
/// default box lands here), `run/` is `XDG_RUNTIME_DIR` with a plain file
/// standing in for the Wayland socket (bwrap binds it like any file), and
/// `box/` is the box the test passes with `-b`. Removed afterwards unless
/// the test failed.
struct Scratch {
    dir: PathBuf,
}

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target/test-tmp")
            .join(format!("it-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::create_dir_all(dir.join("run")).unwrap();
        fs::write(dir.join("run/wayland-0"), "").unwrap();
        Scratch { dir }
    }

    fn home(&self) -> PathBuf {
        self.dir.join("home")
    }

    fn box_dir(&self) -> PathBuf {
        self.dir.join("box")
    }

    /// `<box>$HOME`: where the sandbox's home lives on disk.
    fn box_home(&self) -> PathBuf {
        self.box_dir().join(self.home().strip_prefix("/").unwrap())
    }

    /// A path under the scratch dir, as a string for the command line.
    fn path(&self, rel: &str) -> String {
        self.dir.join(rel).to_str().unwrap().to_string()
    }

    /// The binary in this environment; the box is not chosen yet.
    fn sandbox(&self) -> Command {
        let mut c = Command::new(SANDBOX);
        c.env("HOME", self.home())
            .env("XDG_RUNTIME_DIR", self.dir.join("run"))
            .env("WAYLAND_DISPLAY", "wayland-0")
            .env_remove("LD_PRELOAD");
        c
    }

    /// `sandbox <opts> -b <box> sh -c <script>`, run to completion.
    fn sh(&self, opts: &[&str], script: &str) -> Output {
        self.sandbox()
            .args(opts)
            .arg("-b")
            .arg(self.box_dir())
            .args(["sh", "-c", script])
            .output()
            .expect("runs sandbox")
    }

    /// `sandbox -b <box> --reset-system`
    fn reset(&self) -> Output {
        self.sandbox()
            .arg("-b")
            .arg(self.box_dir())
            .arg("--reset-system")
            .output()
            .expect("runs sandbox")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        // keep the evidence when the test failed
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// The run succeeded; its stdout as lines.
fn lines(o: &Output) -> Vec<String> {
    assert!(
        o.status.success(),
        "sandbox failed ({}): {}",
        o.status,
        stderr(o)
    );
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .map(str::to_string)
        .collect()
}

fn have(tool: &str) -> bool {
    Command::new(tool)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

/// Can bwrap build the sandbox here? Needs unprivileged user namespaces and
/// the GPU node the binary always binds.
fn bwrap_works() -> bool {
    static OK: OnceLock<bool> = OnceLock::new();
    *OK.get_or_init(|| {
        Command::new("bwrap")
            .args([
                "--unshare-all",
                "--ro-bind",
                "/",
                "/",
                "--dev-bind",
                "/dev/dri",
                "/dev/dri",
                "/bin/true",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    })
}

/// -n needs pasta and the namespace tools, and a host with a default route
/// for pasta to pick its interface from.
fn net_works() -> bool {
    let default_route = fs::read_to_string("/proc/net/route")
        .map(|t| {
            t.lines()
                .any(|l| l.split_whitespace().nth(1) == Some("00000000"))
        })
        .unwrap_or(false);
    have("pasta") && have("nsenter") && have("unshare") && default_route
}

/// How many mounts are under `dir` (from /proc/self/mounts).
fn mounts_under(dir: &Path) -> usize {
    fs::read_to_string("/proc/self/mounts")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split(' ').nth(1))
        .filter(|m| Path::new(m).starts_with(dir))
        .count()
}

fn wait_for(child: &mut Child, timeout: Duration) -> ExitStatus {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(s) = child.try_wait().unwrap() {
            return s;
        }
        assert!(Instant::now() < deadline, "sandbox did not exit in time");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn uid() -> String {
    // SAFETY: always succeeds
    unsafe { libc::getuid() }.to_string()
}

#[test]
fn home_is_the_box_and_the_real_one_is_hidden() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    let s = Scratch::new("home");
    fs::write(s.home().join("secret"), "").unwrap();
    let o = s.sh(
        &[],
        r#"echo "$HOME"; ls -A "$HOME" | wc -l; test -e "$HOME/secret" && echo visible || echo hidden; echo kept > "$HOME/kept"; id -u; id -g"#,
    );
    let out = lines(&o);
    assert_eq!(out[0], s.home().to_str().unwrap()); // $HOME is the same path...
    assert_eq!(out[1], "0"); // ...but empty: the box's, not the real one
    assert_eq!(out[2], "hidden");
    assert_eq!(out[3], uid());
    assert_eq!(out[4], unsafe { libc::getgid() }.to_string());
    // what the app wrote is in the box, laid out like /
    assert_eq!(
        fs::read_to_string(s.box_home().join("kept")).unwrap(),
        "kept\n"
    );
    assert!(!s.home().join("kept").exists());
}

#[test]
fn system_is_read_only_offline_and_renamed() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    let s = Scratch::new("system");
    let o = s.sh(
        &[],
        "cat /proc/sys/kernel/hostname; \
         tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' '; \
         touch /usr/x 2>/dev/null && echo writable || echo read-only; \
         touch /etc/x 2>/dev/null && echo writable || echo read-only; \
         test -e /var && echo var || echo no-var; \
         ls -A /tmp | wc -l; \
         echo \"${DBUS_SESSION_BUS_ADDRESS-unset}\"; \
         echo \"$WAYLAND_DISPLAY\"; stat -c %a \"$XDG_RUNTIME_DIR\"; \
         test -e \"$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY\" && echo socket",
    );
    assert_eq!(
        lines(&o),
        [
            "sandbox",
            "lo", // the only interface: no network
            "read-only",
            "read-only",
            "no-var", // only a box with a system layer has /var
            "0",      // a fresh tmpfs
            "unset",  // no D-Bus
            "wayland-0",
            "700",
            "socket",
        ]
    );
}

#[test]
fn exit_status_stdin_and_stdout_pass_through() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    let s = Scratch::new("stdio");
    let o = s.sh(&[], "exit 7");
    assert_eq!(o.status.code(), Some(7));
    let mut child = s
        .sandbox()
        .arg("-b")
        .arg(s.box_dir())
        .args(["sh", "-c", "tr a-z A-Z"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
    let o = child.wait_with_output().unwrap();
    assert_eq!(lines(&o), ["HELLO"]);
}

#[test]
fn binds_at_their_real_paths_with_the_symlink_recreated() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    let s = Scratch::new("binds");
    fs::create_dir(s.dir.join("shared")).unwrap();
    fs::create_dir(s.dir.join("ro")).unwrap();
    fs::write(s.dir.join("ro/data"), "data").unwrap();
    fs::create_dir(s.dir.join("private")).unwrap();
    std::os::unix::fs::symlink(s.dir.join("shared"), s.dir.join("link")).unwrap();
    let real = fs::canonicalize(s.dir.join("shared")).unwrap();
    // -W through the symlink: the app starts in the real dir, and the link
    // works inside too; -r is readable but not writable
    let o = s.sh(
        &["-W", &s.path("link"), "-r", &s.path("ro")],
        &format!(
            "pwd; echo made > f; test -L {link} && echo link; echo via-link > {link}/g; \
             cat {ro}/data; echo; touch {ro}/x 2>/dev/null && echo writable || echo read-only; \
             test -e {other} && echo visible || echo hidden",
            link = s.path("link"),
            ro = s.path("ro"),
            other = s.path("private") // the rest of the scratch dir is not bound
        ),
    );
    assert_eq!(
        lines(&o),
        [
            real.to_str().unwrap(),
            "link",
            "data",
            "read-only",
            "hidden"
        ]
    );
    assert_eq!(
        fs::read_to_string(s.dir.join("shared/f")).unwrap(),
        "made\n"
    );
    assert_eq!(
        fs::read_to_string(s.dir.join("shared/g")).unwrap(),
        "via-link\n"
    );
    assert!(!s.dir.join("ro/x").exists());
    // -d wins over -W's start dir
    let o = s.sh(&["-W", &s.path("shared"), "-d", "/usr"], "pwd");
    assert_eq!(lines(&o), ["/usr"]);
}

#[test]
fn default_and_per_app_boxes_are_created_under_home() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    let s = Scratch::new("boxes");
    let rel_home = s.home();
    let rel_home = rel_home.strip_prefix("/").unwrap();
    let sandboxes = s.home().join("sandboxes");
    let o = s.sandbox().args(["sh", "-c", "true"]).output().unwrap();
    lines(&o);
    assert!(sandboxes.join("default").join(rel_home).is_dir());
    // -a: named after the binary's path; -b NAME: under ~/sandboxes
    let o = s
        .sandbox()
        .args(["-a", "/usr/bin/sh", "-c", "true"])
        .output()
        .unwrap();
    lines(&o);
    assert!(sandboxes.join("usr-bin-sh").join(rel_home).is_dir());
    let o = s
        .sandbox()
        .args(["-b", "named", "sh", "-c", "true"])
        .output()
        .unwrap();
    lines(&o);
    assert!(sandboxes.join("named").join(rel_home).is_dir());
}

#[test]
fn usage_errors_and_help_through_the_binary() {
    let s = Scratch::new("usage");
    let o = s.sandbox().output().unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(stderr(&o).starts_with("usage: sandbox"));
    let o = s.sandbox().arg("-h").output().unwrap();
    assert_eq!(o.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&o.stdout).contains("--reset-system"));
    let o = s.sandbox().arg("--bogus").arg("sh").output().unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(stderr(&o).contains("unrecognized option '--bogus'"));
    let o = s.sandbox().arg("no-such-app-here").output().unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert!(stderr(&o).contains("app not found: no-such-app-here"));
    let o = s
        .sandbox()
        .args(["-w", "/nonexistent/dir", "sh"])
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert!(stderr(&o).contains("bind dir not found: /nonexistent/dir"));
    // resetting a box without a layer is a no-op that succeeds
    let o = s.reset();
    assert_eq!(o.status.code(), Some(0), "{}", stderr(&o));
    assert!(s.box_home().is_dir());
}

#[test]
fn system_layer_lifecycle() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    require!(have("fuse-overlayfs"), "fuse-overlayfs is not installed");
    let s = Scratch::new("layer");
    let b = s.box_dir();

    // --root: fake root, the shim preloaded, the system writable. mkdir
    // mode 000 then chmod is what dpkg does for every directory; chown to
    // an id the sandbox doesn't have "succeeds"
    let o = s.sh(
        &["--root"],
        "id -u; echo \"$LD_PRELOAD\"; \
         mkdir -m 000 /opt/d && chmod 755 /opt/d && echo x > /opt/d/f && echo shim-ok; \
         chown 12345:12345 /opt/d/f && echo chown-ok; \
         echo marker > /usr/local/it-marker && echo installed; \
         test -d /var/lib && echo var",
    );
    assert_eq!(
        lines(&o),
        [
            "0",
            "/usr/lib/sandbox-rootshim.so",
            "shim-ok",
            "chown-ok",
            "installed",
            "var"
        ]
    );
    // the changes are in the box, the host untouched, the mounts gone
    for d in ["usr", "etc", "opt", "var", ".work", ".mnt"] {
        assert!(b.join(d).is_dir(), "{d}");
    }
    assert_eq!(
        fs::read_to_string(b.join("usr/local/it-marker")).unwrap(),
        "marker\n"
    );
    assert_eq!(fs::read_to_string(b.join("opt/d/f")).unwrap(), "x\n");
    assert!(!Path::new("/usr/local/it-marker").exists());
    assert_eq!(mounts_under(&b.join(".mnt")), 0);

    // a plain run on the same box: the real uid again, the installed files
    // part of the read-only system (root's, not the app's), its own files its
    let o = s.sh(
        &[],
        "id -u; cat /usr/local/it-marker; stat -c %u /usr/local/it-marker; cat /opt/d/f; \
         echo y >> /usr/local/it-marker 2>/dev/null && echo writable || echo read-only; \
         touch /usr/local/new 2>/dev/null && echo writable || echo read-only; \
         echo own > \"$HOME/own\" && stat -c %u \"$HOME/own\"",
    );
    let out = lines(&o);
    assert_eq!(out[0], uid());
    assert_eq!(out[1], "marker");
    assert_ne!(out[2], uid(), "installed file must not be the app's");
    assert_eq!(out[3], "x");
    assert_eq!(out[4], "read-only");
    assert_eq!(out[5], "read-only");
    assert_eq!(out[6], uid());
    assert_eq!(mounts_under(&b.join(".mnt")), 0);
    assert_eq!(
        fs::read_to_string(b.join("usr/local/it-marker")).unwrap(),
        "marker\n"
    );

    // --reset-system: the layer goes, the home stays
    let o = s.reset();
    assert_eq!(o.status.code(), Some(0), "{}", stderr(&o));
    for d in ["usr", "etc", "opt", "var", ".work", ".mnt"] {
        assert!(!b.join(d).exists(), "{d} should be gone");
    }
    assert_eq!(
        fs::read_to_string(s.box_home().join("own")).unwrap(),
        "own\n"
    );
    // and the next plain run sees the host's system again
    let o = s.sh(
        &[],
        "test -e /usr/local/it-marker && echo still || echo gone",
    );
    assert_eq!(lines(&o), ["gone"]);
    assert!(!b.join("usr").exists());
}

#[test]
fn reset_is_refused_while_the_box_is_mounted() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    require!(have("fuse-overlayfs"), "fuse-overlayfs is not installed");
    let s = Scratch::new("busy");
    let b = s.box_dir();
    let mut running = s
        .sandbox()
        .args(["--root", "-b"])
        .arg(&b)
        .args(["sh", "-c", "echo ready; exec sleep 30"])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(running.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    assert_eq!(line.trim(), "ready");
    assert!(mounts_under(&b.join(".mnt")) > 0);

    let o = s.reset();
    assert_eq!(o.status.code(), Some(1));
    assert!(stderr(&o).contains("is in use"), "{}", stderr(&o));
    assert!(b.join("usr").is_dir());

    // SIGTERM to sandbox stops bwrap, and the layers are unmounted on the way out
    // SAFETY: our own child's pid
    unsafe { libc::kill(running.id() as i32, libc::SIGTERM) };
    let status = wait_for(&mut running, Duration::from_secs(10));
    assert!(!status.success());
    assert_eq!(mounts_under(&b.join(".mnt")), 0);
    let o = s.reset();
    assert_eq!(o.status.code(), Some(0), "{}", stderr(&o));
    assert!(!b.join("usr").exists());
}

#[test]
fn net_gives_an_interface_and_keeps_the_real_uid() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    require!(
        net_works(),
        "pasta/nsenter/unshare or a default route is missing"
    );
    let s = Scratch::new("net");
    let o = s.sh(
        &["-n"],
        "id -u; cat /etc/resolv.conf; tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | grep -vc '^lo$'; \
         echo f > \"$HOME/f\" && stat -c %u \"$HOME/f\"; exit 7",
    );
    // the app's exit status comes through (bwrap keeps reporting on the
    // status pipe until it exits)
    assert_eq!(o.status.code(), Some(7), "{}", stderr(&o));
    let out: Vec<&str> = std::str::from_utf8(&o.stdout).unwrap().lines().collect();
    assert_eq!(out[0], uid(), "un-rooted after pasta's root mapping");
    assert_eq!(out[1], "nameserver 169.254.1.1");
    assert_eq!(out[2], "1", "one interface besides lo");
    assert_eq!(out[3], uid(), "files stay the user's");
    assert_eq!(fs::read_to_string(s.box_home().join("f")).unwrap(), "f\n");
}

#[test]
fn net_with_root_keeps_root() {
    require!(bwrap_works(), "bwrap can't create a sandbox here");
    require!(
        net_works(),
        "pasta/nsenter/unshare or a default route is missing"
    );
    require!(have("fuse-overlayfs"), "fuse-overlayfs is not installed");
    let s = Scratch::new("net-root");
    let o = s.sh(&["-n", "--root"], "id -u; cat /etc/resolv.conf");
    assert_eq!(lines(&o), ["0", "nameserver 169.254.1.1"]);
    assert_eq!(mounts_under(&s.box_dir().join(".mnt")), 0);
}
