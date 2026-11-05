//! Dünne Linux-Anbindung an eine ausdrücklich gewählte lokale PMT-CLI.
//! Keine Konvertierungslogik; vollständiges JSON bleibt einschließlich unbekannter Felder erhalten.

use serde_json::Value;
use std::{
    ffi::OsString,
    fs::{self, File},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{
            fs::MetadataExt,
            process::{CommandExt, ExitStatusExt},
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
        Arc, Weak,
    },
    thread,
    time::{Duration, Instant},
};

const STDOUT_LIMIT: usize = 16 * 1024 * 1024;
const STDERR_LIMIT: usize = 64 * 1024;
const PROGRESS_LINE_LIMIT: usize = 16 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    InvalidCli,
    Spawn,
    Cancelled,
    TimedOut,
    OutputLimit,
    Capture,
    InvalidResponse,
    CliFailure,
    Cleanup,
}

#[derive(Debug, Clone)]
pub struct BridgeError {
    pub kind: ErrorKind,
    pub message: String,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub stderr: String,
    /// Auch fehlgeschlagene Stapelantworten mit bereits erzeugten Dokumenten bleiben verfügbar.
    pub response: Option<Value>,
}
impl BridgeError {
    fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            exit_code: None,
            signal: None,
            stderr: String::new(),
            response: None,
        }
    }
    pub fn message(&self) -> &str {
        &self.message
    }
}
impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for BridgeError {}

#[derive(Debug)]
pub enum Event {
    ProgressText(String),
    Finished(Result<Value, BridgeError>),
}

#[derive(Debug, Clone)]
pub struct JobHandle {
    state: Arc<AtomicBool>,
}
impl JobHandle {
    pub fn cancel(&self) {
        self.state.store(true, Ordering::Release);
    }
}

/// Handle bis Finished behalten. Nach Wegfall aller Handle-Kopien wird der Job abgebrochen.
pub struct Job {
    pub handle: JobHandle,
    pub events: Receiver<Event>,
}

#[derive(Debug, Clone)]
pub struct Policy {
    pub timeout: Duration,
    pub termination_grace: Duration,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(3600),
            termination_grace: Duration::from_millis(500),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Bridge {
    cli: PathBuf,
    guard: Option<PathBuf>,
    policy: Policy,
}
#[derive(Debug, Clone, Copy)]
enum Operation {
    Catalog,
    Conversion,
    Other,
}
impl Bridge {
    pub fn new(cli: impl Into<PathBuf>) -> Self {
        Self {
            cli: cli.into(),
            guard: None,
            policy: Policy::default(),
        }
    }
    pub fn with_policy(cli: impl Into<PathBuf>, policy: Policy) -> Self {
        Self {
            cli: cli.into(),
            guard: None,
            policy,
        }
    }
    pub fn with_guard(mut self, guard: impl Into<PathBuf>) -> Self {
        self.guard = Some(guard.into());
        self
    }
    pub fn cli_path(&self) -> &Path {
        &self.cli
    }
    pub fn start_conversion(&self, arguments: Vec<OsString>) -> Job {
        self.start(arguments, Operation::Conversion)
    }
    pub fn start_operation(&self, arguments: Vec<OsString>) -> Job {
        self.start(arguments, Operation::Other)
    }
    pub fn start_catalog(&self) -> Job {
        self.start(vec![OsString::from("--formats")], Operation::Catalog)
    }
    pub fn catalog(&self) -> Result<Value, BridgeError> {
        let job = self.start_catalog();
        loop {
            match job.events.recv() {
                Ok(Event::Finished(result)) => return result,
                Ok(Event::ProgressText(_)) => {}
                Err(_) => {
                    return Err(BridgeError::new(
                        ErrorKind::Capture,
                        "The CLI worker ended without a result.",
                    ))
                }
            }
        }
    }
    fn start(&self, arguments: Vec<OsString>, operation: Operation) -> Job {
        let (sender, events) = mpsc::sync_channel(64);
        let state = Arc::new(AtomicBool::new(false));
        let weak = Arc::downgrade(&state);
        let bridge = self.clone();
        let failure_sender = sender.clone();
        if let Err(error) = thread::Builder::new()
            .name("pmt-cli".into())
            .spawn(move || {
                let result = bridge.run(arguments, operation, weak, &sender);
                // Fortschritt darf verworfen werden; das finale Ergebnis wird erst nach Cleanup versendet.
                let _ = sender.send(Event::Finished(result));
            })
        {
            let _ = failure_sender.send(Event::Finished(Err(BridgeError::new(
                ErrorKind::Spawn,
                format!("The CLI worker could not start: {error}"),
            ))));
        }
        Job {
            handle: JobHandle { state },
            events,
        }
    }
    fn run(
        &self,
        arguments: Vec<OsString>,
        operation: Operation,
        cancel: Weak<AtomicBool>,
        sender: &SyncSender<Event>,
    ) -> Result<Value, BridgeError> {
        if cancelled(&cancel) {
            return Err(BridgeError::new(
                ErrorKind::Cancelled,
                "Conversion cancelled.",
            ));
        }
        let metadata = fs::metadata(&self.cli).map_err(|e| {
            BridgeError::new(
                ErrorKind::InvalidCli,
                format!("The local CLI could not be opened: {e}"),
            )
        })?;
        if !self.cli.is_absolute()
            || !metadata.is_file()
            || metadata.mode() & 0o111 == 0
            || metadata.mode() & 0o6000 != 0
        {
            return Err(BridgeError::new(
                ErrorKind::InvalidCli,
                "Choose an absolute path to an unprivileged executable PMT CLI.",
            ));
        }
        if self.policy.timeout.is_zero() || self.policy.termination_grace > Duration::from_secs(30)
        {
            return Err(BridgeError::new(
                ErrorKind::Spawn,
                "Invalid CLI process limits.",
            ));
        }
        let guard = self
            .guard
            .clone()
            .unwrap_or_else(|| self.cli.with_file_name("poormans-text-process-guard"));
        let guard_metadata = fs::metadata(&guard).map_err(|e| {
            BridgeError::new(
                ErrorKind::InvalidCli,
                format!("The local PMT process guard is unavailable: {e}"),
            )
        })?;
        if !guard.is_absolute()
            || !guard_metadata.is_file()
            || guard_metadata.mode() & 0o111 == 0
            || guard_metadata.mode() & 0o6000 != 0
        {
            return Err(BridgeError::new(
                ErrorKind::InvalidCli,
                "Choose an absolute unprivileged PMT process guard.",
            ));
        }
        let (lifetime_read, lifetime_write) = pipe()?;
        let (info_read, info_write) = pipe()?;
        let info_source = info_write.as_raw_fd();
        let mut command = Command::new("/usr/bin/bwrap");
        command
            .args([
                "--unshare-pid",
                "--unshare-net",
                "--die-with-parent",
                "--as-pid-1",
                "--new-session",
                "--bind",
                "/",
                "/",
                "--proc",
                "/proc",
                "--dev",
                "/dev",
                "--info-fd",
            ])
            .arg(info_source.to_string())
            .arg("--");
        command
            .arg(&guard)
            .arg("--pmt-ui-guard-v1")
            .arg(self.policy.termination_grace.as_millis().to_string())
            .arg("--")
            .arg(&self.cli)
            .arg("--json");
        if matches!(operation, Operation::Conversion) {
            command.arg("--progress");
        }
        command
            .args(arguments)
            .stdin(Stdio::from(lifetime_read))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let parent = std::process::id() as libc::pid_t;
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    return Err(io::Error::from_raw_os_error(libc::ECANCELED));
                }
                if libc::fcntl(info_source, libc::F_SETFD, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().map_err(|e| {
            BridgeError::new(
                ErrorKind::Spawn,
                format!("The required Linux namespace could not start: {e}"),
            )
        })?;
        drop(info_write);
        let mut owner = NamespaceOwner::new(child, lifetime_write, info_read);
        let output =
            owner.child.stdout.take().ok_or_else(|| {
                BridgeError::new(ErrorKind::Capture, "CLI stdout is unavailable.")
            })?;
        let errors =
            owner.child.stderr.take().ok_or_else(|| {
                BridgeError::new(ErrorKind::Capture, "CLI stderr is unavailable.")
            })?;
        let mut stdout = Capture::new(
            unsafe { File::from_raw_fd(std::os::fd::IntoRawFd::into_raw_fd(output)) },
            false,
        )
        .map_err(|e| BridgeError::new(ErrorKind::Capture, e.to_string()))?;
        let mut stderr = Capture::new(
            unsafe { File::from_raw_fd(std::os::fd::IntoRawFd::into_raw_fd(errors)) },
            true,
        )
        .map_err(|e| BridgeError::new(ErrorKind::Capture, e.to_string()))?;
        owner.start(&cancel, &mut stderr, sender)?;
        let start = Instant::now();
        let timeout = if matches!(operation, Operation::Catalog) {
            self.policy.timeout.min(Duration::from_secs(30))
        } else {
            self.policy.timeout
        };
        let mut stop: Option<(ErrorKind, Instant, String)> = None;
        let mut status = None;
        loop {
            for capture in [&mut stdout, &mut stderr] {
                if let Err(e) = capture.drain(sender) {
                    stop.get_or_insert((
                        ErrorKind::Capture,
                        Instant::now(),
                        format!("CLI capture failed: {e}"),
                    ));
                }
            }
            if stdout.exceeded {
                stop.get_or_insert((
                    ErrorKind::OutputLimit,
                    Instant::now(),
                    "CLI JSON exceeds the 16 MiB output limit.".into(),
                ));
            }
            if cancelled(&cancel) {
                stop.get_or_insert((
                    ErrorKind::Cancelled,
                    Instant::now(),
                    "Conversion cancelled.".into(),
                ));
            }
            if start.elapsed() >= timeout {
                stop.get_or_insert((
                    ErrorKind::TimedOut,
                    Instant::now(),
                    "The CLI job exceeded its time limit.".into(),
                ));
            }
            if let Some((_, stopped, _)) = &stop {
                if !owner.terminated {
                    owner.request_stop();
                    owner.terminated = true;
                }
                if stopped.elapsed() >= self.policy.termination_grace {
                    owner.kill_namespace();
                }
            }
            if status.is_none() {
                status = owner.child.try_wait().map_err(|e| {
                    BridgeError::new(
                        ErrorKind::Cleanup,
                        format!("CLI exit could not be observed: {e}"),
                    )
                })?;
                if status.is_some() {
                    owner.reaped = true;
                }
            }
            let alive = !owner.namespace_ended()?;
            if status.is_some() && alive && stop.is_none() {
                stop = Some((
                    ErrorKind::Cleanup,
                    Instant::now(),
                    "The CLI ended while child processes remained active.".into(),
                ));
            }
            if status.is_some() && !alive && stdout.closed && stderr.closed {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        stderr.finish_progress(sender);
        let status = status
            .ok_or_else(|| BridgeError::new(ErrorKind::Cleanup, "CLI exit status is missing."))?;
        let parsed = serde_json::from_slice::<Value>(&stdout.bytes);
        let stderr_text = String::from_utf8_lossy(&stderr.bytes).into_owned();
        let error = |kind, message, response| BridgeError {
            kind,
            message,
            exit_code: status.code(),
            signal: status.signal(),
            stderr: stderr_text.clone(),
            response,
        };
        if let Some((kind, _, message)) = stop {
            return Err(error(kind, message, parsed.as_ref().ok().cloned()));
        }
        if !status.success() {
            let message = parsed
                .as_ref()
                .ok()
                .and_then(|x| x.get("error"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    if stderr_text.trim().is_empty() {
                        format!("The CLI exited unsuccessfully: {status}")
                    } else {
                        stderr_text.trim().to_owned()
                    }
                });
            return Err(error(
                ErrorKind::CliFailure,
                message,
                parsed.as_ref().ok().cloned(),
            ));
        }
        let value = parsed.map_err(|e| {
            error(
                ErrorKind::InvalidResponse,
                format!("The CLI did not return complete valid JSON: {e}"),
                None,
            )
        })?;
        if value.get("ok").and_then(Value::as_bool) != Some(true)
            || value.get("error").is_some_and(|error| !error.is_null())
        {
            let message = value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("The CLI reported a failed operation.")
                .to_owned();
            return Err(BridgeError {
                kind: ErrorKind::CliFailure,
                message,
                exit_code: status.code(),
                signal: status.signal(),
                stderr: stderr_text,
                response: Some(value),
            });
        }
        ResultSummary::from_value(&value).map_err(|mut e| {
            e.exit_code = status.code();
            e.signal = status.signal();
            e.stderr = stderr_text.clone();
            e.response = Some(value.clone());
            e
        })?;
        let validation = match operation {
            Operation::Catalog => validate_catalog(&value),
            Operation::Conversion => validate_conversion(&value, None),
            Operation::Other => Ok(()),
        };
        validation.map_err(|mut e| {
            e.stderr = stderr_text;
            e.exit_code = status.code();
            e.signal = status.signal();
            e.response = Some(value.clone());
            e
        })?;
        Ok(value)
    }
}

fn cancelled(state: &Weak<AtomicBool>) -> bool {
    state
        .upgrade()
        .map(|x| x.load(Ordering::Acquire))
        .unwrap_or(true)
}

/// Bekannte Felder sind typisiert; raw enthält sämtliche zusätzlichen Producerfelder.
#[derive(Debug, Clone)]
pub struct ResultSummary {
    pub version: String,
    pub output_directory: Option<PathBuf>,
    pub markdown_file: Option<PathBuf>,
    pub assets: Vec<PathBuf>,
    pub documents: Vec<Value>,
    pub diagnostics: Vec<Value>,
    pub diagnostic_groups: Vec<Value>,
    pub warnings: Vec<Value>,
    pub results: Vec<Value>,
    pub raw: Value,
}
impl ResultSummary {
    pub fn from_value(value: &Value) -> Result<Self, BridgeError> {
        Self::inherited(value, None)
    }
    fn inherited(value: &Value, inherited_version: Option<&str>) -> Result<Self, BridgeError> {
        let invalid = || {
            BridgeError::new(
                ErrorKind::InvalidResponse,
                "The CLI response has invalid known field types.",
            )
        };
        if value.get("ok").and_then(Value::as_bool) != Some(true)
            || value.get("error").is_some_and(|error| !error.is_null())
        {
            return Err(invalid());
        }
        let version = value
            .get("version")
            .and_then(Value::as_str)
            .or(inherited_version)
            .ok_or_else(invalid)?
            .to_owned();
        let path = |key: &str| -> Result<Option<PathBuf>, BridgeError> {
            match value.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(x)) => {
                    let p = PathBuf::from(x);
                    if !p.is_absolute() {
                        Err(invalid())
                    } else {
                        Ok(Some(p))
                    }
                }
                _ => Err(invalid()),
            }
        };
        let array = |key: &str| -> Result<Vec<Value>, BridgeError> {
            match value.get(key) {
                None | Some(Value::Null) => Ok(Vec::new()),
                Some(Value::Array(x)) => Ok(x.clone()),
                _ => Err(invalid()),
            }
        };
        for key in ["documents", "diagnostics", "diagnosticGroups", "results"] {
            if !array(key)?.iter().all(Value::is_object) {
                return Err(invalid());
            }
        }
        if !array("warnings")?.iter().all(Value::is_string) {
            return Err(invalid());
        }
        let assets = array("assets")?
            .into_iter()
            .map(|x| {
                let p = x.as_str().map(PathBuf::from).ok_or_else(invalid)?;
                if p.is_absolute() {
                    Ok(p)
                } else {
                    Err(invalid())
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            version,
            output_directory: path("outputDirectory")?,
            markdown_file: path("markdownFile")?,
            assets,
            documents: array("documents")?,
            diagnostics: array("diagnostics")?,
            diagnostic_groups: array("diagnosticGroups")?,
            warnings: array("warnings")?,
            results: array("results")?,
            raw: value.clone(),
        })
    }
}
fn validate_catalog(value: &Value) -> Result<(), BridgeError> {
    let invalid = || {
        BridgeError::new(
            ErrorKind::InvalidResponse,
            "The CLI format catalog is invalid.",
        )
    };
    let formats = value
        .get("formats")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    for format in formats {
        if format.get("format").and_then(Value::as_str).is_none()
            || format.get("available").and_then(Value::as_bool).is_none()
            || !format
                .get("extensions")
                .and_then(Value::as_array)
                .map(|a| a.iter().all(Value::is_string))
                .unwrap_or(false)
        {
            return Err(invalid());
        }
    }
    Ok(())
}
fn validate_conversion(value: &Value, inherited_version: Option<&str>) -> Result<(), BridgeError> {
    let summary = ResultSummary::inherited(value, inherited_version)?;
    if let Some(results) = value.get("results").and_then(Value::as_array) {
        for result in results {
            validate_conversion(result, Some(&summary.version))?;
        }
        return Ok(());
    }
    if summary.output_directory.is_none() || summary.markdown_file.is_none() {
        return Err(BridgeError::new(
            ErrorKind::InvalidResponse,
            "A successful conversion has no output directory or Markdown file.",
        ));
    }
    Ok(())
}

struct Capture {
    file: File,
    bytes: Vec<u8>,
    pending: Vec<u8>,
    stderr: bool,
    exceeded: bool,
    closed: bool,
}
impl Capture {
    fn new(file: File, stderr: bool) -> io::Result<Self> {
        let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            file,
            bytes: Vec::new(),
            pending: Vec::new(),
            stderr,
            exceeded: false,
            closed: false,
        })
    }
    fn drain(&mut self, sender: &SyncSender<Event>) -> io::Result<()> {
        if self.closed {
            return Ok(());
        }
        let mut buffer = [0u8; 8192];
        for _ in 0..16 {
            match self.file.read(&mut buffer) {
                Ok(0) => {
                    self.closed = true;
                    break;
                }
                Ok(count) => {
                    if self.stderr {
                        self.bytes.extend_from_slice(&buffer[..count]);
                        if self.bytes.len() > STDERR_LIMIT {
                            self.bytes.drain(..self.bytes.len() - STDERR_LIMIT);
                        }
                        for byte in &buffer[..count] {
                            if *byte == b'\n' || self.pending.len() == PROGRESS_LINE_LIMIT {
                                self.finish_progress(sender);
                            }
                            if *byte != b'\n' {
                                self.pending.push(*byte);
                            }
                        }
                    } else {
                        let accepted = count.min(STDOUT_LIMIT.saturating_sub(self.bytes.len()));
                        self.bytes.extend_from_slice(&buffer[..accepted]);
                        self.exceeded |= accepted < count;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
    fn finish_progress(&mut self, sender: &SyncSender<Event>) {
        if !self.pending.is_empty() {
            let text = String::from_utf8_lossy(&self.pending).into_owned();
            self.pending.clear();
            match sender.try_send(Event::ProgressText(text)) {
                Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
            }
        }
    }
}

fn pipe() -> Result<(File, File), BridgeError> {
    let mut descriptors = [-1; 2];
    if unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(BridgeError::new(
            ErrorKind::Spawn,
            format!(
                "The supervision pipe could not be created: {}",
                io::Error::last_os_error()
            ),
        ));
    }
    Ok(unsafe {
        (
            File::from_raw_fd(descriptors[0]),
            File::from_raw_fd(descriptors[1]),
        )
    })
}

struct NamespaceOwner {
    child: Child,
    namespace: Option<Pin>,
    lifetime: Option<File>,
    info: File,
    reaped: bool,
    terminated: bool,
}
impl NamespaceOwner {
    fn new(child: Child, lifetime: File, info: File) -> Self {
        Self {
            child,
            namespace: None,
            lifetime: Some(lifetime),
            info,
            reaped: false,
            terminated: false,
        }
    }
    fn start(
        &mut self,
        cancel: &Weak<AtomicBool>,
        stderr: &mut Capture,
        sender: &SyncSender<Event>,
    ) -> Result<(), BridgeError> {
        if unsafe { libc::fcntl(self.info.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
            return Err(BridgeError::new(
                ErrorKind::Spawn,
                "The namespace handshake pipe could not be configured.",
            ));
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut bytes = Vec::new();
        loop {
            if cancelled(cancel) {
                return Err(BridgeError::new(
                    ErrorKind::Cancelled,
                    "Conversion cancelled before start.",
                ));
            }
            let mut buffer = [0u8; 4096];
            match self.info.read(&mut buffer) {
                Ok(n) => {
                    bytes.extend_from_slice(&buffer[..n]);
                }
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => {
                    return Err(BridgeError::new(
                        ErrorKind::Spawn,
                        format!("The namespace handshake failed: {e}"),
                    ))
                }
            }
            if bytes.len() > 4096 {
                return Err(BridgeError::new(
                    ErrorKind::Spawn,
                    "The namespace handshake exceeds its limit.",
                ));
            }
            if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                let pid = value
                    .get("child-pid")
                    .and_then(Value::as_i64)
                    .filter(|p| *p > 1 && *p <= i32::MAX as i64)
                    .ok_or_else(|| {
                        BridgeError::new(
                            ErrorKind::Spawn,
                            "The namespace handshake has no valid PID.",
                        )
                    })? as i32;
                let pin = Pin::bind(pid).map_err(|e| {
                    BridgeError::new(
                        ErrorKind::Spawn,
                        format!("Required namespace pidfd binding failed before CLI start: {e}"),
                    )
                })?;
                if !descendant_of(pid, self.child.id() as i32)
                    || pin.ended().map_err(|e| {
                        BridgeError::new(
                            ErrorKind::Spawn,
                            format!("The bound namespace could not be observed: {e}"),
                        )
                    })?
                {
                    return Err(BridgeError::new(
                        ErrorKind::Spawn,
                        "The namespace could not be bound to its own wrapper.",
                    ));
                }
                self.namespace = Some(pin);
                #[cfg(test)]
                if let Some(path) = std::env::var_os("PMT_TEST_GATE_OBSERVER") {
                    fs::write(path, pid.to_string()).unwrap();
                    // Deterministische Testbarriere: der Besitzer wird vor ACK getötet.
                    loop {
                        thread::sleep(Duration::from_secs(1));
                    }
                }
                if cancelled(cancel) {
                    return Err(BridgeError::new(
                        ErrorKind::Cancelled,
                        "Conversion cancelled before start.",
                    ));
                }
                self.lifetime
                    .as_mut()
                    .unwrap()
                    .write_all(&[1])
                    .map_err(|e| {
                        BridgeError::new(
                            ErrorKind::Spawn,
                            format!("The namespace start gate failed: {e}"),
                        )
                    })?;
                #[cfg(test)]
                if let Some(path) = std::env::var_os("PMT_TEST_NAMESPACE_OBSERVER") {
                    fs::write(path, pid.to_string()).unwrap();
                }
                return Ok(());
            }
            stderr
                .drain(sender)
                .map_err(|e| BridgeError::new(ErrorKind::Capture, e.to_string()))?;
            if let Some(status) = self
                .child
                .try_wait()
                .map_err(|e| BridgeError::new(ErrorKind::Cleanup, e.to_string()))?
            {
                self.reaped = true;
                let mut error = BridgeError::new(
                    ErrorKind::Spawn,
                    format!("The required Linux PID/network namespace could not start: {status}"),
                );
                error.stderr = String::from_utf8_lossy(&stderr.bytes).into_owned();
                error.exit_code = status.code();
                error.signal = status.signal();
                return Err(error);
            }
            if Instant::now() >= deadline {
                return Err(BridgeError::new(
                    ErrorKind::Spawn,
                    "The namespace start handshake timed out.",
                ));
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
    fn request_stop(&mut self) {
        if self
            .lifetime
            .as_mut()
            .is_some_and(|pipe| pipe.write_all(&[2]).is_err())
        {
            self.lifetime.take();
        }
    }
    fn kill_namespace(&self) {
        if let Some(pin) = &self.namespace {
            pin.signal(libc::SIGKILL);
        }
    }
    fn namespace_ended(&self) -> Result<bool, BridgeError> {
        let pin = self
            .namespace
            .as_ref()
            .ok_or_else(|| BridgeError::new(ErrorKind::Cleanup, "The namespace was not bound."))?;
        pin.ended().map_err(|e| {
            BridgeError::new(
                ErrorKind::Cleanup,
                format!("The namespace pidfd poll failed: {e}"),
            )
        })
    }
}
impl Drop for NamespaceOwner {
    fn drop(&mut self) {
        // Vor dem ACK bedeutet EOF: keine CLI starten. Nach ACK beendet EOF
        // PID1; sein pidfd bestätigt das Ende des gesamten PID-Namespace.
        self.lifetime.take();
        if self.namespace.is_some() {
            self.kill_namespace();
            while !self.namespace_ended().unwrap_or(false) {
                thread::sleep(Duration::from_millis(5));
            }
        }
        if !self.reaped {
            let _ = self.child.wait();
            self.reaped = true;
        }
    }
}

struct Pin {
    fd: OwnedFd,
}
impl Pin {
    fn bind(pid: libc::pid_t) -> io::Result<Self> {
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            fd: unsafe { OwnedFd::from_raw_fd(fd as i32) },
        })
    }
    fn ended(&self) -> io::Result<bool> {
        let mut p = libc::pollfd {
            fd: self.fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut p, 1, 0) };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        if p.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
            return Err(io::Error::other("invalid namespace pidfd poll"));
        }
        Ok(result > 0 && p.revents & libc::POLLIN != 0)
    }
    #[cfg(test)]
    fn alive(&self) -> bool {
        !self.ended().unwrap()
    }
    fn signal(&self, signal: i32) {
        unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                self.fd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            );
        }
    }
}
fn identity(pid: i32) -> io::Result<(u64, i32, bool)> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat"))?;
    let rest = stat
        .rsplit_once(')')
        .ok_or_else(|| io::Error::other("invalid proc stat"))?
        .1;
    let fields: Vec<_> = rest.split_whitespace().collect();
    let start = fields
        .get(19)
        .and_then(|x| x.parse().ok())
        .ok_or_else(|| io::Error::other("invalid proc start time"))?;
    let parent = fields
        .get(1)
        .and_then(|x| x.parse().ok())
        .ok_or_else(|| io::Error::other("invalid proc parent"))?;
    Ok((
        start,
        parent,
        !matches!(fields.first(), Some(&"Z") | Some(&"X")),
    ))
}
fn descendant_of(mut pid: i32, ancestor: i32) -> bool {
    for _ in 0..128 {
        if pid == ancestor {
            return true;
        }
        match identity(pid) {
            Ok((_, parent, _)) if parent > 1 && parent != pid => pid = parent,
            _ => return false,
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::{
            ffi::OsStringExt,
            fs::{DirBuilderExt, PermissionsExt},
        },
        sync::atomic::AtomicU64,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "pmt-bridge-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn script(&self, body: &str) -> PathBuf {
            let path = self.0.join("fixture-cli");
            fs::write(&path, format!("#!/usr/bin/python3\n{body}\n")).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            path
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn finished(job: &Job) -> Result<Value, BridgeError> {
        loop {
            match job
                .events
                .recv_timeout(Duration::from_secs(15))
                .expect("worker did not finish")
            {
                Event::ProgressText(_) => {}
                Event::Finished(result) => return result,
            }
        }
    }
    fn short(cli: PathBuf) -> Bridge {
        Bridge::with_policy(
            cli,
            Policy {
                timeout: Duration::from_secs(5),
                termination_grace: Duration::from_millis(100),
            },
        )
        .with_guard(std::env::var_os("PMT_TEST_GUARD").unwrap())
    }
    fn wait_for(mut predicate: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(8);
        while !predicate() {
            assert!(Instant::now() < deadline, "fixture state not reached");
            thread::sleep(Duration::from_millis(5));
        }
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn unknown_fields_and_os_arguments_are_preserved() {
        let root = Root::new();
        let cli = root.script("import json,os,sys\nprint(json.dumps({'ok':True,'version':'fixture','future':{'kept':[1,2]},'argument':os.fsencode(sys.argv[-1]).hex()}))");
        let argument = OsString::from_vec(b"literal $HOME;$(false) \xff".to_vec());
        let job = short(cli).start_operation(vec![argument]);
        let value = finished(&job).unwrap();
        assert_eq!(value["future"]["kept"], serde_json::json!([1, 2]));
        assert_eq!(
            value["argument"],
            "6c69746572616c2024484f4d453b242866616c73652920ff"
        );
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn missing_binary_and_false_success_are_errors_with_raw_response() {
        let job = bridge("/nonexistent/pmt-cli").start_catalog();
        assert_eq!(finished(&job).unwrap_err().kind, ErrorKind::InvalidCli);
        let root = Root::new();
        let cli = root.script("import json\nprint(json.dumps({'ok':False,'version':'fixture','error':'EXPECTED ERROR','future':42}))");
        let job = short(cli).start_operation(vec![]);
        let error = finished(&job).unwrap_err();
        assert_eq!(error.kind, ErrorKind::CliFailure);
        assert_eq!(error.response.unwrap()["future"], 42);
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn contradictory_error_response_cannot_become_success() {
        let root = Root::new();
        let cli = root.script("import json\nprint(json.dumps({'ok':True,'version':'fixture','error':'failed despite flag'}))");
        let job = short(cli).start_operation(vec![]);
        let error = finished(&job).unwrap_err();
        assert_eq!(error.kind, ErrorKind::CliFailure);
        assert!(error.response.is_some());
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn json_must_be_complete_and_stdout_is_bounded() {
        let root = Root::new();
        let cli = root.script("import os\nos.write(1,b'{\"ok\":true')");
        let job = short(cli).start_operation(vec![]);
        assert_eq!(finished(&job).unwrap_err().kind, ErrorKind::InvalidResponse);
        fs::remove_file(root.0.join("fixture-cli")).unwrap();
        let cli = root.script("import os\nwhile True: os.write(1,b'x'*65536)");
        let job = short(cli).start_operation(vec![]);
        assert_eq!(finished(&job).unwrap_err().kind, ErrorKind::OutputLimit);
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn stderr_and_event_queue_remain_bounded_without_a_consumer() {
        let root = Root::new();
        let cli = root.script("import os,json\nos.write(2,b'E'*1048576)\nprint(json.dumps({'ok':False,'version':'fixture','error':'bounded'}))");
        let job = short(cli).start_operation(vec![]);
        thread::sleep(Duration::from_millis(200));
        let error = finished(&job).unwrap_err();
        assert_eq!(error.kind, ErrorKind::CliFailure);
        assert!(error.stderr.len() <= STDERR_LIMIT);
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn batch_entries_inherit_version_and_partial_results_are_kept() {
        let value = serde_json::json!({"ok":true,"version":"future","results":[{"ok":true,"outputDirectory":"/tmp/output","markdownFile":"/tmp/output/index.md","assets":["/tmp/output/a.png"],"documents":[{"markdownFile":"/tmp/output/one.md","future":42}]}]});
        assert!(validate_conversion(&value, None).is_ok());
        let summary = ResultSummary::from_value(&value).unwrap();
        assert_eq!(summary.results[0]["documents"][0]["future"], 42);
        let root = Root::new();
        let cli = root.script("import json,sys\nprint(json.dumps({'ok':False,'version':'fixture','results':[{'ok':True,'markdownFile':'/tmp/kept.md'},{'ok':False,'error':'one failed'}]}))\nsys.exit(65)");
        let job = short(cli).start_conversion(vec![]);
        let error = finished(&job).unwrap_err();
        assert_eq!(error.exit_code, Some(65));
        assert_eq!(
            error.response.unwrap()["results"][0]["markdownFile"],
            "/tmp/kept.md"
        );
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn cancel_waits_for_detached_descendant_and_does_not_signal_unrelated_process() {
        let root = Root::new();
        let cli = root.script("import os,sys,time,signal\nfrom pathlib import Path\nr=Path(sys.argv[-1]);signal.signal(signal.SIGTERM,signal.SIG_IGN)\npid=os.fork()\nif pid==0:\n os.setsid()\n (r/'ready').write_text(str(os.getpid()))\n while True:\n  with (r/'heartbeat').open('a') as f:f.write('tick\\n')\n  time.sleep(.005)\nwhile True:time.sleep(.01)");
        let mut unrelated = Command::new("/usr/bin/sleep").arg("30").spawn().unwrap();
        let job = short(cli).start_operation(vec![root.0.clone().into_os_string()]);
        wait_for(|| root.0.join("ready").exists());
        job.handle.cancel();
        let result = finished(&job).unwrap_err();
        assert_eq!(result.kind, ErrorKind::Cancelled);
        let before = fs::read(root.0.join("heartbeat")).unwrap();
        thread::sleep(Duration::from_millis(80));
        assert_eq!(fs::read(root.0.join("heartbeat")).unwrap(), before);
        assert!(unrelated.try_wait().unwrap().is_none());
        unrelated.kill().unwrap();
        unrelated.wait().unwrap();
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn timeout_and_dropped_handles_cancel_the_owned_child() {
        let root = Root::new();
        let executable = root.script("import time\nwhile True:time.sleep(.01)");
        let timed_bridge = Bridge::with_policy(
            executable.clone(),
            Policy {
                timeout: Duration::from_millis(80),
                termination_grace: Duration::from_millis(50),
            },
        )
        .with_guard(std::env::var_os("PMT_TEST_GUARD").unwrap());
        let job = timed_bridge.start_operation(Vec::new());
        assert_eq!(finished(&job).unwrap_err().kind, ErrorKind::TimedOut);
        let job = bridge(executable).start_operation(Vec::new());
        let Job { handle, events } = job;
        drop(handle);
        loop {
            if let Event::Finished(result) = events.recv_timeout(Duration::from_secs(5)).unwrap() {
                assert_eq!(result.unwrap_err().kind, ErrorKind::Cancelled);
                break;
            }
        }
    }
    fn bridge(cli: impl Into<PathBuf>) -> Bridge {
        Bridge::new(cli).with_guard(
            std::env::var_os("PMT_TEST_GUARD").expect("set PMT_TEST_GUARD to the built guard"),
        )
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn immediate_exit_cannot_escape_namespace_barrier() {
        for _ in 0..24 {
            let root = Root::new();
            let heartbeat = root.0.join("heartbeat");
            fs::write(&heartbeat, b"").unwrap();
            let script = root.script(&format!("import os,signal,time,json\npid=os.fork()\nif pid==0:\n os.setsid();signal.signal(signal.SIGTERM,signal.SIG_IGN)\n os.close(1);os.close(2)\n while True:\n  with open({:?},'a') as f:f.write('tick\\n')\n  time.sleep(.001)\nprint(json.dumps({{'ok':True,'version':'fixture'}}),flush=True)\nos._exit(0)", heartbeat.to_str().unwrap()));
            let job = short(script).start_operation(Vec::new());
            // PID1 räumt Nachkommen auf; Success ist erst nach Namespace-Ende zulässig.
            finished(&job).unwrap();
            let before = fs::metadata(&heartbeat).unwrap().len();
            thread::sleep(Duration::from_millis(10));
            assert_eq!(fs::metadata(&heartbeat).unwrap().len(), before);
        }
    }
    #[test]
    #[ignore = "internal pidfd fault-injection fixture subprocess"]
    fn pidfd_failure_process() {
        let root = PathBuf::from(std::env::var_os("PMT_OWNER_ROOT").unwrap());
        let mut filter = [
            libc::sock_filter {
                code: 0x20,
                jt: 0,
                jf: 0,
                k: 0,
            },
            libc::sock_filter {
                code: 0x15,
                jt: 0,
                jf: 1,
                k: libc::SYS_pidfd_open as u32,
            },
            libc::sock_filter {
                code: 0x06,
                jt: 0,
                jf: 0,
                k: 0x00050000 | libc::EMFILE as u32,
            },
            libc::sock_filter {
                code: 0x06,
                jt: 0,
                jf: 0,
                k: 0x7fff0000,
            },
        ];
        let program = libc::sock_fprog {
            len: filter.len() as u16,
            filter: filter.as_mut_ptr(),
        };
        unsafe {
            assert_eq!(libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), 0);
            assert_eq!(libc::prctl(libc::PR_SET_SECCOMP, 2, &program), 0);
        }
        let job = bridge(root.join("fixture-cli")).start_operation(Vec::new());
        let error = finished(&job).unwrap_err();
        assert_eq!(error.kind, ErrorKind::Spawn, "{error:?}");
        assert!(error.message.contains("pidfd binding failed"), "{error:?}");
        assert!(!root.join("started").exists());
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn pidfd_emfile_fails_before_workload_start() {
        let root = Root::new();
        root.script(&format!(
            "from pathlib import Path\nPath({:?}).write_text('BAD')",
            root.0.join("started").to_str().unwrap()
        ));
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::pidfd_failure_process",
                "--ignored",
                "--nocapture",
            ])
            .env("PMT_OWNER_ROOT", &root.0)
            .status()
            .unwrap();
        assert!(status.success());
        assert!(!root.0.join("started").exists());
    }
    #[test]
    #[ignore = "requires explicit built guard, real CLI and host namespaces"]
    fn ui_loss_before_ack_starts_no_workload() {
        for _ in 0..12 {
            let root = Root::new();
            prepare_blocking_fixture(&root.0);
            let observer = root.0.join("namespace.pid");
            let mut ui = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "tests::ui_owner_process",
                    "--ignored",
                    "--nocapture",
                ])
                .env("PMT_TEST_CLI", cli())
                .env("PMT_OWNER_ROOT", &root.0)
                .env("PMT_TEST_GATE_OBSERVER", &observer)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            wait_for(|| observer.exists());
            let pid: i32 = fs::read_to_string(&observer).unwrap().parse().unwrap();
            let namespace = Pin::bind(pid).unwrap();
            ui.kill().unwrap();
            ui.wait().unwrap();
            wait_for(|| !namespace.alive());
            assert!(!find_file(&root.0, "escaped.ready").is_some());
            assert!(!root.0.join("output").exists());
        }
    }

    fn cli() -> PathBuf {
        PathBuf::from(
            std::env::var_os("PMT_TEST_CLI").expect("set PMT_TEST_CLI to the built real CLI"),
        )
    }
    fn sha256(path: &Path) -> String {
        let output = Command::new("/usr/bin/sha256sum")
            .arg(path)
            .output()
            .unwrap();
        assert!(output.status.success());
        String::from_utf8(output.stdout)
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap()
            .to_owned()
    }
    #[test]
    #[ignore = "requires explicit PMT_TEST_CLI; exercised separately against the real producer"]
    fn real_catalog_csv_folder_and_hashes() {
        let root = Root::new();
        let bridge = bridge(cli());
        let catalog = bridge.catalog().unwrap();
        assert!(catalog["formats"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["format"] == "csv" && x["available"] == true));
        let source = root.0.join("Unicode $HOME;$(false).csv");
        fs::write(&source, "Name,Value\nALPHA,Grüße\nBETA,42\n").unwrap();
        let source_hash = sha256(&source);
        let mut previous = None;
        for suffix in ["first", "second"] {
            let job = bridge.start_conversion(vec![
                "--output".into(),
                root.0.join(suffix).into_os_string(),
                "--".into(),
                source.clone().into_os_string(),
            ]);
            let value = finished(&job).unwrap();
            let summary = ResultSummary::from_value(&value).unwrap();
            let markdown = summary.markdown_file.unwrap();
            let content = fs::read_to_string(&markdown).unwrap();
            for token in ["Name", "Value", "ALPHA", "Grüße", "BETA", "42"] {
                assert_eq!(content.matches(token).count(), 1, "{content}");
            }
            let hash = sha256(&markdown);
            println!("CSV source_sha256={source_hash} markdown_sha256={hash}");
            if let Some(previous) = &previous {
                assert_eq!(&hash, previous);
            }
            previous = Some(hash);
            assert_eq!(sha256(&source), source_hash);
        }
        let inputs = root.0.join("inputs");
        fs::create_dir(&inputs).unwrap();
        fs::copy(&source, inputs.join("A.csv")).unwrap();
        fs::copy(&source, inputs.join("B.csv")).unwrap();
        let job = bridge.start_conversion(vec![
            "--output".into(),
            root.0.join("batch").into_os_string(),
            "--".into(),
            inputs.into_os_string(),
        ]);
        let value = finished(&job).unwrap();
        assert_eq!(value["results"].as_array().unwrap().len(), 2);
    }
    #[test]
    #[ignore = "requires real CLI, guard and host namespaces"]
    fn real_readonly_source_and_fifo() {
        let root = Root::new();
        let source = root.0.join("readonly.csv");
        fs::write(&source, "Name,Value\nALPHA,42\n").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o444)).unwrap();
        let before = fs::metadata(&source).unwrap();
        let hash = sha256(&source);
        let job = bridge(cli()).start_conversion(vec![
            "--output".into(),
            root.0.join("converted").into_os_string(),
            "--".into(),
            source.clone().into_os_string(),
        ]);
        finished(&job).unwrap();
        let after = fs::metadata(&source).unwrap();
        assert_eq!(sha256(&source), hash);
        assert_eq!(
            (
                before.ino(),
                before.mode(),
                before.mtime(),
                before.mtime_nsec()
            ),
            (after.ino(), after.mode(), after.mtime(), after.mtime_nsec())
        );
        let fifo = root.0.join("fifo.csv");
        let name = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        let job = bridge(cli()).start_conversion(vec![
            "--output".into(),
            root.0.join("bad").into_os_string(),
            "--".into(),
            fifo.into_os_string(),
        ]);
        let error = finished(&job).unwrap_err();
        assert_eq!(error.kind, ErrorKind::CliFailure, "{error:?}");
        assert!(!root.0.join("bad").exists());
    }

    fn prepare_blocking_fixture(root: &Path) {
        fs::write(
            root.join("source.rtf"),
            b"{\\rtf1\\ansi Real parent-loss fixture}",
        )
        .unwrap();
        let tool = root.join("pandoc-fixture");
        fs::write(&tool, "#!/usr/bin/python3\nimport os,time,signal\nfrom pathlib import Path\nr=Path.cwd()\npid=os.fork()\nif pid==0:\n os.setsid();signal.signal(signal.SIGTERM,signal.SIG_IGN)\n (r/'escaped.ready').write_text(str(os.getpid()))\n while True:\n  with (r/'heartbeat').open('a') as f:f.write('tick\\n')\n  time.sleep(.005)\nwhile True:time.sleep(.01)\n").unwrap();
        fs::set_permissions(&tool, fs::Permissions::from_mode(0o755)).unwrap();
    }
    fn conversion_arguments(root: &Path) -> Vec<OsString> {
        vec![
            "--pandoc".into(),
            root.join("pandoc-fixture").into_os_string(),
            "--output".into(),
            root.join("output").into_os_string(),
            "--".into(),
            root.join("source.rtf").into_os_string(),
        ]
    }
    #[test]
    #[ignore = "requires real Swift CLI and working mandatory namespaces"]
    fn real_cancel_waits_for_swift_namespace() {
        let root = Root::new();
        prepare_blocking_fixture(&root.0);
        let job = bridge(cli()).start_conversion(conversion_arguments(&root.0));
        wait_for(|| find_file(&root.0, "escaped.ready").is_some());
        let heartbeat = find_file(&root.0, "heartbeat").unwrap();
        let heartbeat_file = File::open(&heartbeat).unwrap();
        job.handle.cancel();
        let error = finished(&job).unwrap_err();
        assert_eq!(error.kind, ErrorKind::Cancelled);
        assert_eq!(error.exit_code, Some(130), "{error:?}");
        let before = heartbeat_file.metadata().unwrap().len();
        thread::sleep(Duration::from_millis(80));
        assert_eq!(heartbeat_file.metadata().unwrap().len(), before);
        assert!(!root.0.join("output").exists());
    }
    #[test]
    #[ignore = "internal owner-loss fixture subprocess"]
    fn ui_owner_process() {
        let cli = cli();
        let root =
            PathBuf::from(std::env::var_os("PMT_OWNER_ROOT").expect("internal fixture root"));
        let job = bridge(cli).start_conversion(conversion_arguments(&root));
        loop {
            if let Ok(Event::Finished(result)) = job.events.recv_timeout(Duration::from_millis(50))
            {
                panic!("owner fixture ended early: {result:?}");
            }
        }
    }
    fn find_file(root: &Path, name: &str) -> Option<PathBuf> {
        for entry in fs::read_dir(root).ok()? {
            let entry = entry.ok()?;
            let ty = entry.file_type().ok()?;
            if ty.is_file() && entry.file_name() == name {
                return Some(entry.path());
            }
            if ty.is_dir() {
                if let Some(path) = find_file(&entry.path(), name) {
                    return Some(path);
                }
            }
        }
        None
    }
    #[test]
    #[ignore = "requires real Swift CLI and working mandatory namespaces"]
    fn parent_loss_kills_real_cli_and_swift_namespace() {
        let root = Root::new();
        prepare_blocking_fixture(&root.0);
        let observer = root.0.join("namespace.pid");
        let mut ui = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::ui_owner_process",
                "--ignored",
                "--nocapture",
            ])
            .env("PMT_TEST_CLI", cli())
            .env("PMT_OWNER_ROOT", &root.0)
            .env("PMT_TEST_NAMESPACE_OBSERVER", &observer)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        wait_for(|| find_file(&root.0, "escaped.ready").is_some());
        let pid = fs::read_to_string(observer).unwrap().parse().unwrap();
        let namespace = Pin::bind(pid).unwrap();
        let heartbeat = find_file(&root.0, "heartbeat").unwrap();
        ui.kill().unwrap();
        ui.wait().unwrap();
        wait_for(|| !namespace.alive());
        let before = fs::read(&heartbeat).unwrap();
        thread::sleep(Duration::from_millis(80));
        assert_eq!(fs::read(heartbeat).unwrap(), before);
    }
}
