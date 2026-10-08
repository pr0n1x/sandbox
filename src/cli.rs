//! Command line: getopt-compatible (`+`: options stop at the first
//! non-option, so the app's own flags pass through), with the same help text
//! the script had.

use crate::util::{absolute, die, realpath_e, realpath_m};
use std::path::PathBuf;

pub const USAGE: &str = "usage: sandbox [-i|--interactive] [-w|--bind DIR]... [-W|--workdir DIR]... [-r|--ro-bind DIR]... [-d|--chdir DIR] [-b|--box NAME|DIR] [-a|--app-box] [-n|--net[IFACE]] [-6|--ipv6] [-x|--x11] [-p|--permissions LIST]... [--root] /usr/bin/someapp [args...]
       sandbox [-b NAME|DIR] --reset-system";

pub fn help() -> String {
    let user = std::env::var("USER").unwrap_or_else(|_| "user".into());
    format!(
        "usage: sandbox [options] /usr/bin/someapp [args...]
       sandbox [-b NAME|DIR] --reset-system

Run an app inside strict bubblewrap isolation: own namespaces, no network,
read-only system, a private home, Wayland/GPU/sound passed through.
Everything the app keeps lives in its box, ~/sandboxes/<name>/, laid out
like the root filesystem:
  home/{user:<18}    bound as $HOME
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
"
    )
}

/// A -w/-W/-r bind: DIR's real path, bound at itself; if DIR was given
/// through a symlink, that symlink is recreated inside so the path as
/// given keeps working.
#[derive(Debug, Clone)]
pub struct Bind {
    pub ro: bool,
    pub real: PathBuf,
    pub symlink_from: Option<PathBuf>,
}

#[derive(Debug, Default)]
pub struct Opts {
    pub interactive: bool,
    pub binds: Vec<Bind>,
    pub workdir: Option<PathBuf>,
    pub chdir: Option<PathBuf>,
    pub box_: Option<String>,
    pub app_box: bool,
    pub net: bool,
    pub out_if: Option<String>,
    pub ipv6: bool,
    pub x11: bool,
    pub camera: bool,
    pub root: bool,
    pub reset: bool,
    /// the app and its arguments, verbatim
    pub cmd: Vec<String>,
}

fn usage() -> ! {
    eprintln!("{USAGE}");
    std::process::exit(2)
}

fn bind(ro: bool, dir: &str) -> Bind {
    let given = PathBuf::from(dir);
    let real = realpath_e(&given).unwrap_or_else(|_| die(1, format!("bind dir not found: {dir}")));
    let orig = absolute(&given);
    Bind {
        ro,
        real: real.clone(),
        symlink_from: (orig != real).then_some(orig),
    }
}

pub fn parse(args: Vec<String>) -> Opts {
    let mut o = Opts::default();
    let mut it = args.into_iter().peekable();
    // value of an option that takes one: attached ("-bNAME", "--box=NAME") or the next arg
    fn value(
        attached: Option<String>,
        it: &mut std::iter::Peekable<std::vec::IntoIter<String>>,
        name: &str,
    ) -> String {
        attached.or_else(|| it.next()).unwrap_or_else(|| {
            eprintln!("sandbox: option requires an argument -- '{name}'");
            usage()
        })
    }
    while let Some(arg) = it.peek().cloned() {
        if arg == "--" {
            it.next();
            break;
        }
        if !arg.starts_with('-') || arg == "-" {
            break; // the app: stop here, its flags are its own
        }
        it.next();
        if let Some(long) = arg.strip_prefix("--") {
            let (name, attached) = match long.split_once('=') {
                Some((n, v)) => (n, Some(v.to_string())),
                None => (long, None),
            };
            match name {
                "help" => {
                    print!("{}", help());
                    std::process::exit(0)
                }
                "interactive" => o.interactive = true,
                "bind" => o.binds.push(bind(false, &value(attached, &mut it, name))),
                "workdir" => {
                    let b = bind(false, &value(attached, &mut it, name));
                    o.workdir = Some(b.real.clone());
                    o.binds.push(b)
                }
                "ro-bind" => o.binds.push(bind(true, &value(attached, &mut it, name))),
                "chdir" => {
                    o.chdir = Some(realpath_m(&PathBuf::from(value(attached, &mut it, name))))
                }
                "box" => o.box_ = Some(value(attached, &mut it, name)),
                "app-box" => o.app_box = true,
                "net" => {
                    o.net = true;
                    o.out_if = attached.filter(|s| !s.is_empty())
                } // IFACE only attached: --net=IFACE
                "ipv6" => o.ipv6 = true,
                "x11" => o.x11 = true,
                "permissions" => permissions(&mut o, &value(attached, &mut it, name)),
                "root" => o.root = true,
                "reset-system" => o.reset = true,
                _ => {
                    eprintln!("sandbox: unrecognized option '--{name}'");
                    usage()
                }
            }
            continue;
        }
        // short options, possibly clustered ("-ix"); a value option takes the
        // rest of the cluster as its value ("-bNAME") or the next arg
        let shorts: Vec<char> = arg[1..].chars().collect();
        let mut i = 0;
        while i < shorts.len() {
            let c = shorts[i];
            let rest: String = shorts[i + 1..].iter().collect();
            let attached = (!rest.is_empty()).then_some(rest);
            let takes_value = matches!(c, 'w' | 'W' | 'r' | 'd' | 'b' | 'p');
            match c {
                'h' => {
                    print!("{}", help());
                    std::process::exit(0)
                }
                'i' => o.interactive = true,
                'a' => o.app_box = true,
                '6' => o.ipv6 = true,
                'x' => o.x11 = true,
                'n' => {
                    o.net = true;
                    o.out_if = attached;
                    i = shorts.len();
                    continue;
                } // -nIFACE: the rest is the interface
                'w' => o.binds.push(bind(false, &value(attached, &mut it, "w"))),
                'W' => {
                    let b = bind(false, &value(attached, &mut it, "W"));
                    o.workdir = Some(b.real.clone());
                    o.binds.push(b)
                }
                'r' => o.binds.push(bind(true, &value(attached, &mut it, "r"))),
                'd' => o.chdir = Some(realpath_m(&PathBuf::from(value(attached, &mut it, "d")))),
                'b' => o.box_ = Some(value(attached, &mut it, "b")),
                'p' => permissions(&mut o, &value(attached, &mut it, "p")),
                _ => {
                    eprintln!("sandbox: invalid option -- '{c}'");
                    usage()
                }
            }
            if takes_value {
                break;
            } // the value consumed the rest of the cluster
            i += 1;
        }
    }
    o.cmd = it.collect();
    if o.cmd.is_empty() && !o.reset {
        usage()
    }
    o
}

/// -p NAME[,NAME...]: named grants of host resources, so new ones don't each
/// need an option letter
fn permissions(o: &mut Opts, list: &str) {
    for perm in list.split(',') {
        match perm {
            "camera" => o.camera = true,
            "x11" => o.x11 = true,
            "" => {}
            other => die(
                2,
                format!("unknown permission: {other} (known: camera, x11)"),
            ),
        }
    }
}
