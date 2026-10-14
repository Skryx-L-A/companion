// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! A deadline that measures the machine instead of assuming one.
//!
//! Test-only, shared between [`crate::vault`] and [`crate::subagent`], both of which spawn a
//! stub shell script and need a deadline that only a real hang trips — never the ordinary
//! fork/exec latency of `sh` under a full-workspace parallel test run. The same idea lives in
//! `tests/test-support` for the crates under `tests/`; `app/` cannot depend on that crate
//! (`tests/` is what pulls `app/` in, never the other way, so `app/` still builds once it is
//! split into the public repo), so this is the copy for the crates under `app/` that need it.

use std::time::{Duration, Instant};

/// Ten runs of spawning a trivial `#!/bin/sh` script, the slowest one taken. Measured once
/// per test binary and cached — it is meant to track the machine's steady state, not one
/// lucky or unlucky instant.
///
/// Measured 2026-09-05 under artificial load (`yes > /dev/null`, eight of them, an 18-core
/// machine): spawning `true` — a real binary, no interpreter — stayed under 100 ms worst of
/// ten, while spawning an equivalent one-line `#!/bin/sh` script reached 2.7 s worst of ten
/// under the same load. A shell has to open and read the script before it can even reach the
/// line the test cares about, and every one of those extra syscalls is another chance to be
/// descheduled under contention — `true` alone does not see that cost at all, which is why a
/// deadline built from it stayed too tight while the vault and subagent tests, which spawn
/// shell scripts, still flaked. This probe spawns the same shape of thing the tests do.
pub(crate) fn process_overhead() -> Duration {
    static MEASURED: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *MEASURED.get_or_init(measure_shell_overhead)
}

fn measure_shell_overhead() -> Duration {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::temp_dir().join(format!(
        "companion-brain-test-support-probe-{}",
        std::process::id()
    ));
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").expect("the probe script is writable");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
        .expect("the probe script is executable");
    let mut worst = Duration::from_millis(1);
    for _ in 0..10 {
        let started = Instant::now();
        let _ = std::process::Command::new(&path).output();
        worst = worst.max(started.elapsed());
    }
    let _ = std::fs::remove_file(&path);
    worst
}

/// A deadline for a call that is meant to succeed: far enough above what this machine needs
/// that only a hang trips it, and never below the floor a fast machine would make too tight.
pub(crate) fn generous(floor: Duration) -> Duration {
    floor.max(process_overhead() * 8)
}
