//! -n: bwrap creates the namespaces (its AppArmor profile allows userns);
//! pasta only *attaches* to the sandbox netns via setns(), which the Ubuntu
//! userns restriction doesn't gate — so pasta needs no profile of its own.
//! The app is held on bwrap's --block-fd until pasta has configured the
//! network.

use crate::util::{die, output, run as run_tool, warn};
use std::ffi::OsString;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::io::{FromRawFd, OwnedFd, AsRawFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

/// fds bwrap gets: status report, block, and the resolv.conf contents
pub const STATUS_FD: RawFd = 100;
pub const BLOCK_FD: RawFd = 101;
pub const RESOLV_FD: RawFd = 102;

pub struct Net {
    /// -4, or nothing with -6 (pasta's defaults are both)
    pub pasta_ip: Vec<String>,
    /// -nIFACE: mirror IFACE inside and pin pasta's sockets to it
    pub out_args: Vec<String>,
    /// DNS forwarding: pasta's resolver address inside, and how it forwards
    pub fwd_args: Vec<String>,
    pub dns_fwd: String,
}

pub fn configure(out_if: Option<&str>, ipv6: bool) -> Net {
    let mut net = Net {
        pasta_ip: if ipv6 { vec![] } else { vec!["-4".into()] },
        out_args: Vec::new(),
        fwd_args: vec!["--dns-forward".into(), "169.254.1.1".into()],
        dns_fwd: "169.254.1.1".into(),
    };
    let Some(iface) = out_if else { return net };
    if !Path::new("/sys/class/net").join(iface).exists() {
        die(1, format!("no such interface: {iface}"));
    }
    // SO_BINDTODEVICE pins pasta's host sockets to IFACE, so its traffic
    // bypasses e.g. a WireGuard fwmark default route and leaves through IFACE
    net.out_args = vec!["-i".into(), iface.into(), "--outbound-if4".into(), iface.into()];
    if ipv6 {
        net.out_args.extend(["--outbound-if6".into(), iface.into()]);
    }
    // pinned sockets can't reach a loopback resolver (systemd-resolved's
    // 127.0.0.53 stub, pasta's default --dns-host from /etc/resolv.conf), so
    // forward DNS to IFACE's own upstream servers instead — not the global
    // list, which may hold servers only reachable through the tunnel being
    // bypassed. --dns-host takes one server per IP version
    if let Some(upstream) = output("resolvectl", &["dns", iface]) {
        let servers = upstream.split_once(':').map(|(_, s)| s).unwrap_or("");
        let ns4 = servers.split_whitespace().find(|s| !s.contains(':'));
        let ns6 = servers.split_whitespace().find(|s| s.contains(':'));
        let pasta_has_dns_host = output("pasta", &["--help"])
            .or_else(|| Command::new("pasta").arg("--help").output().ok().map(|o| String::from_utf8_lossy(&o.stderr).into_owned()))
            .map(|h| h.contains("--dns-host"))
            .unwrap_or(false);
        if pasta_has_dns_host {
            if let Some(s) = ns4 { net.out_args.extend(["--dns-host".into(), s.into()]); }
            if let (Some(s), true) = (ns6, ipv6) { net.out_args.extend(["--dns-host".into(), s.into()]); }
        } else if let Some(s) = ns4 {
            // old pasta (< 2024_10_30, e.g. Ubuntu 24.04) can't retarget the
            // forwarder: point the sandbox resolv.conf straight at the upstream
            // server; --no-map-gw so a gateway-hosted DNS reaches the real
            // gateway instead of being remapped to the host; --dns none: no
            // "Couldn't get any nameserver" noise
            net.dns_fwd = s.into();
            net.fwd_args = vec!["--no-map-gw".into(), "--dns".into(), "none".into()];
        }
    }
    net
}

/// The pid of the running bwrap, for the signal handler.
static CHILD: AtomicI32 = AtomicI32::new(0);

extern "C" fn forward_signal(sig: libc::c_int) {
    let pid = CHILD.load(Ordering::SeqCst);
    if pid > 0 {
        // SAFETY: plain syscall
        unsafe { libc::kill(pid, sig) };
    }
}

/// Make SIGINT/SIGTERM stop the sandbox (bwrap is in its own session with
/// --new-session, so a terminal's Ctrl-C only reaches us), and let the
/// normal exit path clean up.
pub fn forward_signals_to(child: &Child) {
    CHILD.store(child.id() as i32, Ordering::SeqCst);
    for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: installing an async-signal-safe handler
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = forward_signal as extern "C" fn(libc::c_int) as usize;
            sa.sa_flags = libc::SA_RESTART;
            libc::sigaction(sig, &sa, std::ptr::null_mut());
        }
    }
}

fn pipe() -> (OwnedFd, OwnedFd) {
    let mut fds = [0; 2];
    // SAFETY: valid array
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } < 0 {
        die(1, format!("pipe: {}", std::io::Error::last_os_error()));
    }
    // SAFETY: fresh fds we own
    unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
}

/// Exit status of a finished child as a shell would report it.
pub fn exit_code(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

/// Run bwrap with networking: spawn it held on the block fd, attach pasta,
/// set sysctls, release it, write the app's nested uid map, wait.
pub fn run(bwrap_args: &[OsString], app_wrap: &[String], app: &Path, app_args: &[String], net: &Net, snap: bool) -> i32 {
    let (status_r, status_w) = pipe();
    let (block_r, block_w) = pipe();
    let (resolv_r, resolv_w) = pipe();
    {
        let mut w = fs::File::from(resolv_w);
        let _ = write!(w, "nameserver {}\n", net.dns_fwd);
    } // closed: bwrap reads the data up to EOF

    let mut cmd = Command::new("bwrap");
    cmd.arg("--json-status-fd").arg(STATUS_FD.to_string())
        .arg("--block-fd").arg(BLOCK_FD.to_string())
        .args(bwrap_args)
        .args(app_wrap)
        .arg(app)
        .args(app_args);
    let (sw, br, rr) = (status_w.as_raw_fd(), block_r.as_raw_fd(), resolv_r.as_raw_fd());
    // SAFETY: only dup2 calls in the child, which are async-signal-safe
    unsafe {
        cmd.pre_exec(move || {
            for (from, to) in [(sw, STATUS_FD), (br, BLOCK_FD), (rr, RESOLV_FD)] {
                if libc::dup2(from, to) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().unwrap_or_else(|e| die(1, format!("cannot run bwrap: {e}")));
    forward_signals_to(&child);
    drop(status_w);
    drop(block_r);
    drop(resolv_r);
    let kill_all = |pids: &[i32]| for p in pids { if *p > 0 { unsafe { libc::kill(*p, libc::SIGKILL) }; } };

    // the first status message arrives once the namespaces exist; it also
    // carries namespace inode numbers, so pick the child-pid field specifically
    let line = read_line_timeout(status_r, Duration::from_secs(10)).unwrap_or_default();
    let child_pid: i32 = line
        .split("\"child-pid\":")
        .nth(1)
        .and_then(|s| s.trim_start().split(|c: char| !c.is_ascii_digit()).next())
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| {
            kill_all(&[child.id() as i32]);
            die(1, "bwrap did not report a child pid")
        });

    let mut pasta = vec!["--config-net".to_string(), "--quiet".into()];
    pasta.extend(net.pasta_ip.iter().cloned());
    pasta.extend(net.out_args.iter().cloned());
    pasta.extend(net.fwd_args.iter().cloned());
    pasta.extend(["--userns".into(), format!("/proc/{child_pid}/ns/user"), "--netns".into(), format!("/proc/{child_pid}/ns/net")]);
    let pasta_ref: Vec<&str> = pasta.iter().map(String::as_str).collect();
    if !run_tool("pasta", &pasta_ref) {
        kill_all(&[child_pid, child.id() as i32]);
        die(1, "pasta failed (is the passt package installed?)");
    }

    // a fresh netns has net.ipv4.ping_group_range empty, and modern ping drops
    // its file caps and only tries unprivileged ICMP datagram sockets, gated
    // by that sysctl; /proc/sys/net follows the writer's netns. Only gid 0 is
    // mapped in the sandbox userns, so "0 0" is the widest legal range. For
    // snaps, zero max_user_namespaces: the app holds no caps and can't gain
    // any under no_new_privs, so it cannot raise the limit back
    let mut sysctls = String::from("echo 0 0 > /proc/sys/net/ipv4/ping_group_range");
    if snap {
        sysctls += "; echo 0 > /proc/sys/user/max_user_namespaces";
    }
    let _ = Command::new("nsenter")
        .args(["--preserve-credentials", "-U", "-n", "-t", &child_pid.to_string(), "sh", "-c", &sysctls])
        .stderr(std::process::Stdio::null())
        .status();

    let outer_ns = fs::read_link(format!("/proc/{child_pid}/ns/user")).ok();
    // network is up; release the app
    let _ = fs::File::from(block_w).write_all(b"\n");

    // the released app (see APP_WRAP in main) now unshares its nested userns
    // and waits; once that shows up, write the 0 -> real uid/gid mapping from
    // here. The app is a child of bwrap's mini-init (child_pid, still in the
    // outer ns). nsenter into the outer ns first (via the init): the maps may
    // only be written from the nested ns's parent userns, and the host is the
    // grandparent. As the outer ns owns the nested one, joining it grants the
    // needed caps, and a single line mapping one's own euid/egid is always allowed
    if !app_wrap.is_empty() {
        let mut mapped = false;
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(5) {
            if !Path::new(&format!("/proc/{child_pid}")).exists() {
                break; // app already gone
            }
            let app_pid = fs::read_to_string(format!("/proc/{child_pid}/task/{child_pid}/children"))
                .ok()
                .and_then(|s| s.split_whitespace().next().map(str::to_string));
            if let Some(app_pid) = app_pid {
                let ns = fs::read_link(format!("/proc/{app_pid}/ns/user")).ok();
                if ns.is_some() && ns != outer_ns {
                    let script = format!(
                        "echo deny > /proc/{app_pid}/setgroups && echo '{} 0 1' > /proc/{app_pid}/gid_map && echo '{} 0 1' > /proc/{app_pid}/uid_map",
                        crate::util::gid(), crate::util::uid()
                    );
                    mapped = Command::new("nsenter")
                        .args(["--preserve-credentials", "-U", "-t", &child_pid.to_string(), "sh", "-c", &script])
                        .status()
                        .map(|s| s.success())
                        .unwrap_or(false);
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if !mapped {
            warn("setting the app's uid map failed; it runs as nobody");
        }
    }
    let status = child.wait().unwrap_or_else(|e| die(1, format!("waiting for bwrap: {e}")));
    exit_code(status)
}

/// Read one line from a pipe, giving up after `timeout`.
fn read_line_timeout(fd: OwnedFd, timeout: Duration) -> Option<String> {
    let mut f = fs::File::from(fd);
    let mut line = Vec::new();
    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return None;
        }
        let mut pfd = libc::pollfd { fd: f.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd
        let n = unsafe { libc::poll(&mut pfd, 1, left.as_millis() as i32) };
        if n <= 0 {
            return None;
        }
        let mut b = [0u8; 1];
        match f.read(&mut b) {
            Ok(0) => return (!line.is_empty()).then(|| String::from_utf8_lossy(&line).into_owned()),
            Ok(_) if b[0] == b'\n' => return Some(String::from_utf8_lossy(&line).into_owned()),
            Ok(_) => line.push(b[0]),
            Err(_) => return None,
        }
    }
}
