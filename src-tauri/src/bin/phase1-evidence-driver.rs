//! One-shot, local Target-PC evidence driver.
//!
//! `run --report <new-path>` is intentionally its only operational interface.  Operational
//! selections arrive as `Phase1TargetInputsV1` on stdin; identities, keys, receipts, outcomes,
//! and report contents never do.  The reviewed launcher pins this binary; this binary pins the
//! sibling app at compile time.

#[cfg(not(windows))]
fn main() {
    eprintln!("phase1-evidence-driver only runs on the Windows target PC");
    std::process::exit(1);
}

#[cfg(windows)]
fn main() {
    if let Err(error) = run() {
        eprintln!("TargetPc verification failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(windows)]
fn run() -> Result<(), Box<dyn std::error::Error>> {
    use live_subtitle_tool::verification::{
        NativeCommandReceiptV1, Phase1TargetInputsV1, VerificationSession,
    };
    use std::{
        io::{BufRead, BufReader, Write},
        path::PathBuf,
        process::{Command, Stdio},
    };

    let mut args = std::env::args_os();
    let _binary = args.next();
    if args.next().as_deref() != Some(std::ffi::OsStr::new("run"))
        || args.next().as_deref() != Some(std::ffi::OsStr::new("--report"))
    {
        return Err("usage: phase1-evidence-driver run --report <new-path>".into());
    }
    let report = PathBuf::from(args.next().ok_or("missing report path")?);
    if args.next().is_some() || report.exists() {
        return Err("report path must be new and is the only accepted output path".into());
    }

    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    let target: Phase1TargetInputsV1 = serde_json::from_str(&input)?;
    target.validate()?;

    let trusted_app = option_env!("PHASE1_TRUSTED_APP_SHA256")
        .ok_or("approved driver was not compiled with PHASE1_TRUSTED_APP_SHA256")?;
    if trusted_app.len() != 64 || !trusted_app.bytes().all(|value| value.is_ascii_hexdigit()) {
        return Err("trusted app pin is blank or malformed".into());
    }
    let driver_path = std::env::current_exe()?;
    let app_path = fixed_sibling_app(&driver_path)?;
    let actual_app = sha256_file(&app_path)?;
    if !constant_time_equal(actual_app.as_bytes(), trusted_app.as_bytes()) {
        return Err("fixed app bytes do not match the compiled trusted pin".into());
    }
    let driver_hash = sha256_file(&driver_path)?;
    let session = VerificationSession::new_cng(trusted_app.to_ascii_lowercase(), driver_hash)?;

    // `Command` creates anonymous stdin/stdout pipes inherited only by this exact child.  The
    // parent PowerShell process has neither handle nor session key.  Rust's Windows process
    // implementation uses CreateProcessW; no runtime app path or identity is accepted here.
    let mut child = Command::new(&app_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut child_stdin = child.stdin.take().ok_or("missing child stdin")?;
    serde_json::to_writer(&mut child_stdin, &session.bootstrap())?;
    child_stdin.write_all(b"\n")?;
    child_stdin.flush()?;
    drop(child_stdin);

    let stdout = child.stdout.take().ok_or("missing child stdout")?;
    let mut reader = BufReader::new(stdout);
    let mut receipts = Vec::new();
    loop {
        let mut line = String::new();
        let count = reader.read_line(&mut line)?;
        if count == 0 {
            break;
        }
        if count > 65_536 {
            return Err("receipt frame exceeds bounded transport".into());
        }
        receipts.push(serde_json::from_str::<NativeCommandReceiptV1>(&line)?);
    }
    let status = child.wait()?;
    if !status.success() {
        return Err("pinned app did not complete cleanly".into());
    }
    let report_value = session.report(&target, &receipts)?;
    write_new_atomic(&report, &serde_json::to_vec_pretty(&report_value)?)?;
    Ok(())
}

#[cfg(windows)]
fn fixed_sibling_app(
    driver: &std::path::Path,
) -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
    let directory = driver.parent().ok_or("driver has no parent path")?;
    let app = directory.join("live-subtitle-tool.exe");
    if !app.is_file() {
        return Err("fixed sibling app is missing".into());
    }
    Ok(app)
}

#[cfg(windows)]
fn sha256_file(path: &std::path::Path) -> Result<String, Box<dyn std::error::Error>> {
    use sha2::{Digest, Sha256};
    Ok(format!("{:x}", Sha256::digest(std::fs::read(path)?)))
}

#[cfg(windows)]
fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .fold(0u8, |difference, (a, b)| difference | (a ^ b))
            == 0
}

#[cfg(windows)]
fn write_new_atomic(
    path: &std::path::Path,
    bytes: &[u8],
) -> Result<(), Box<dyn std::error::Error>> {
    use std::{fs::OpenOptions, io::Write};
    let parent = path.parent().ok_or("report path has no parent")?;
    let temporary = parent.join(format!(".phase1-evidence-{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    // Windows rename fails if the destination already exists; this preserves create-new semantics.
    std::fs::rename(&temporary, path)?;
    Ok(())
}
