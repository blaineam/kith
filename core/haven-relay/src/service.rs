//! `haven-relay service install` / `uninstall` — wire the relay up to **auto-restart on login**
//! on the current OS, using only built-in OS mechanisms (no extra deps):
//!   • Linux   → a systemd *user* unit (+ `loginctl enable-linger`), or a crontab `@reboot` fallback
//!   • macOS   → a launchd LaunchAgent (`RunAtLoad` + `KeepAlive`)
//!   • Windows → a Scheduled Task at logon (`schtasks /SC ONLOGON`)
//!
//! The installed service runs `haven-relay run` (no args) which reuses the saved circle link,
//! so attach the relay to a circle once (`haven-relay run --link <code>`) before installing.

use std::path::PathBuf;
use std::process::Command;

use anyhow::{anyhow, Result};

#[allow(dead_code)] // used on macOS
const LABEL: &str = "com.haven.relay";
#[allow(dead_code)] // used on Windows
const TASK: &str = "HavenRelay";

fn exe() -> Result<PathBuf> {
    std::env::current_exe().map_err(|e| anyhow!("can't find my own path: {e}"))
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("no HOME directory"))
}

pub fn install() -> Result<()> {
    let exe = exe()?;
    #[cfg(target_os = "linux")]
    return linux_install(&exe);
    #[cfg(target_os = "macos")]
    return macos_install(&exe);
    #[cfg(target_os = "windows")]
    return windows_install(&exe);
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    Err(anyhow!("auto-start isn't supported on this OS yet — run `haven-relay run` from your own startup mechanism"))
}

pub fn uninstall() -> Result<()> {
    #[cfg(target_os = "linux")]
    return linux_uninstall();
    #[cfg(target_os = "macos")]
    return macos_uninstall();
    #[cfg(target_os = "windows")]
    return windows_uninstall();
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    Err(anyhow!("nothing to uninstall on this OS"))
}

// ── Linux: systemd user unit (fallback: crontab @reboot) ─────────────────────────────────
#[cfg(target_os = "linux")]
fn linux_install(exe: &std::path::Path) -> Result<()> {
    let unit_dir = home()?.join(".config/systemd/user");
    let has_systemd = Command::new("systemctl").arg("--user").arg("--version").output().map(|o| o.status.success()).unwrap_or(false);
    if has_systemd {
        std::fs::create_dir_all(&unit_dir)?;
        let unit = format!(
            "[Unit]\nDescription=Haven relay (always-on circle mailbox, ciphertext only)\nAfter=network-online.target\nWants=network-online.target\n\n\
             [Service]\nType=simple\nExecStart={} run\nRestart=always\nRestartSec=5\n\n\
             [Install]\nWantedBy=default.target\n",
            exe.display()
        );
        std::fs::write(unit_dir.join("haven-relay.service"), unit)?;
        // Keep it running after logout, reload, enable + start.
        let _ = Command::new("loginctl").arg("enable-linger").arg(whoami()).status();
        run(Command::new("systemctl").args(["--user", "daemon-reload"]))?;
        run(Command::new("systemctl").args(["--user", "enable", "--now", "haven-relay"]))?;
        println!("✓ Installed systemd user service 'haven-relay' — starts on every login/reboot.");
        println!("  status:  systemctl --user status haven-relay");
        Ok(())
    } else {
        // No systemd → crontab @reboot.
        let line = format!("@reboot {} run >/dev/null 2>&1", exe.display());
        crontab_add(&line)?;
        println!("✓ Added a crontab @reboot entry — the relay starts on every reboot.");
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn linux_uninstall() -> Result<()> {
    let _ = Command::new("systemctl").args(["--user", "disable", "--now", "haven-relay"]).status();
    let _ = std::fs::remove_file(home()?.join(".config/systemd/user/haven-relay.service"));
    let _ = crontab_remove("haven-relay");
    println!("✓ Removed the haven-relay auto-start.");
    Ok(())
}

#[cfg(target_os = "linux")]
fn whoami() -> String {
    std::env::var("USER").unwrap_or_else(|_| "".into())
}

#[cfg(target_os = "linux")]
fn crontab_add(line: &str) -> Result<()> {
    let current = Command::new("crontab").arg("-l").output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    if current.contains(line) {
        return Ok(());
    }
    let mut next = current;
    if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str(line);
    next.push('\n');
    pipe_to(Command::new("crontab").arg("-"), &next)
}

#[cfg(target_os = "linux")]
fn crontab_remove(needle: &str) -> Result<()> {
    let current = Command::new("crontab").arg("-l").output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let kept: String = current.lines().filter(|l| !l.contains(needle)).map(|l| format!("{l}\n")).collect();
    pipe_to(Command::new("crontab").arg("-"), &kept)
}

#[cfg(target_os = "linux")]
fn pipe_to(cmd: &mut Command, input: &str) -> Result<()> {
    use std::io::Write;
    use std::process::Stdio;
    let mut child = cmd.stdin(Stdio::piped()).spawn()?;
    child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?.write_all(input.as_bytes())?;
    let st = child.wait()?;
    if st.success() { Ok(()) } else { Err(anyhow!("command failed")) }
}

// ── macOS: launchd LaunchAgent ───────────────────────────────────────────────────────────
#[cfg(target_os = "macos")]
fn macos_install(exe: &std::path::Path) -> Result<()> {
    let agents = home()?.join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents)?;
    let plist_path = agents.join(format!("{LABEL}.plist"));
    let logs = home()?.join("Library/Logs/haven-relay.log");
    let plist = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\"><dict>\n\
         \t<key>Label</key><string>{LABEL}</string>\n\
         \t<key>ProgramArguments</key><array><string>{}</string><string>run</string></array>\n\
         \t<key>RunAtLoad</key><true/>\n\t<key>KeepAlive</key><true/>\n\
         \t<key>ProcessType</key><string>Background</string>\n\
         \t<key>StandardOutPath</key><string>{}</string>\n\
         \t<key>StandardErrorPath</key><string>{}</string>\n\
         </dict></plist>\n",
        exe.display(), logs.display(), logs.display()
    );
    std::fs::write(&plist_path, plist)?;
    let _ = Command::new("launchctl").arg("unload").arg(&plist_path).status();
    run(Command::new("launchctl").arg("load").arg("-w").arg(&plist_path))?;
    println!("✓ Installed launchd agent '{LABEL}' — starts at login and restarts if it exits.");
    println!("  logs:  {}", logs.display());
    Ok(())
}

#[cfg(target_os = "macos")]
fn macos_uninstall() -> Result<()> {
    let plist_path = home()?.join(format!("Library/LaunchAgents/{LABEL}.plist"));
    let _ = Command::new("launchctl").arg("unload").arg(&plist_path).status();
    let _ = std::fs::remove_file(&plist_path);
    println!("✓ Removed the haven-relay launchd agent.");
    Ok(())
}

// ── Windows: Scheduled Task at logon ─────────────────────────────────────────────────────
#[cfg(target_os = "windows")]
fn windows_install(exe: &std::path::Path) -> Result<()> {
    let tr = format!("\"{}\" run", exe.display());
    let _ = Command::new("schtasks").args(["/Delete", "/TN", TASK, "/F"]).status();
    run(Command::new("schtasks").args(["/Create", "/TN", TASK, "/TR", &tr, "/SC", "ONLOGON", "/RL", "LIMITED", "/F"]))?;
    println!("✓ Installed Scheduled Task '{TASK}' — haven-relay starts on every logon.");
    println!("  start now:  schtasks /Run /TN {TASK}");
    Ok(())
}

#[cfg(target_os = "windows")]
fn windows_uninstall() -> Result<()> {
    run(Command::new("schtasks").args(["/Delete", "/TN", TASK, "/F"]))?;
    println!("✓ Removed the haven-relay Scheduled Task.");
    Ok(())
}

fn run(cmd: &mut Command) -> Result<()> {
    let st = cmd.status().map_err(|e| anyhow!("failed to launch {:?}: {e}", cmd.get_program()))?;
    if st.success() {
        Ok(())
    } else {
        Err(anyhow!("{:?} exited with {st}", cmd.get_program()))
    }
}
