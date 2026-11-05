use crate::model::{OutputFile, tr};
use gtk::glib;
use serde_json::Value;
use std::{
    ffi::CString,
    fs::{File, Metadata},
    io::Read,
    ops::Deref,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Debug)]
pub struct Context {
    value: Value,
    root: Mutex<Option<Arc<Root>>>,
}
impl Context {
    pub fn new(value: Value) -> Self {
        Self {
            value,
            root: Mutex::new(None),
        }
    }
}
impl Deref for Context {
    type Target = Value;
    fn deref(&self) -> &Value {
        &self.value
    }
}
#[derive(Debug)]
struct Root {
    path: PathBuf,
    directory: File,
    identity: (u64, u64),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Stamp {
    pub(crate) fn of(m: &Metadata) -> Self {
        Self {
            device: m.dev(),
            inode: m.ino(),
            size: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}
pub(crate) struct Snapshot {
    pub data: Vec<u8>,
    root: Arc<Root>,
    relative: PathBuf,
    stamp: Stamp,
}
fn err() -> String {
    tr(
        "Datei, Ausgabeverzeichnis oder Prüfhash geändert; Zugriff gesperrt.",
        "File, output directory or fingerprint changed; access blocked.",
    )
    .into()
}
fn normal(path: &Path) -> Result<(), String> {
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        Err("Unsafe relative output path".into())
    } else {
        Ok(())
    }
}
fn openat(parent: &File, name: &std::ffi::OsStr, directory: bool) -> Result<File, String> {
    let name = CString::new(name.as_bytes()).map_err(|_| "NUL in path")?;
    let flags = libc::O_RDONLY
        | libc::O_NOFOLLOW
        | libc::O_NONBLOCK
        | libc::O_CLOEXEC
        | if directory { libc::O_DIRECTORY } else { 0 };
    // Der gehaltene Verzeichnis-FD bindet jede einzelne Komponente; Symlinks werden nie verfolgt.
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn absolute_directory(path: &Path) -> Result<File, String> {
    if !path.is_absolute() {
        return Err("Output directory must be absolute".into());
    }
    let mut dir = File::open("/").map_err(|e| e.to_string())?;
    for part in path.components() {
        match part {
            Component::RootDir => {}
            Component::Normal(name) => dir = openat(&dir, name, true)?,
            _ => return Err("Unsafe directory path".into()),
        }
    }
    Ok(dir)
}
fn relative_file(root: &File, path: &Path) -> Result<File, String> {
    normal(path)?;
    let mut parent = root.try_clone().map_err(|e| e.to_string())?;
    let mut parts = path.components().peekable();
    while let Some(Component::Normal(name)) = parts.next() {
        let file = openat(&parent, name, parts.peek().is_some())?;
        if parts.peek().is_none() {
            return Ok(file);
        }
        parent = file;
    }
    Err("Missing output filename".into())
}
fn root_current(root: &Root) -> Result<(), String> {
    let m = absolute_directory(&root.path)?
        .metadata()
        .map_err(|e| e.to_string())?;
    if (m.dev(), m.ino()) != root.identity {
        return Err(err());
    }
    Ok(())
}
pub(crate) fn fingerprint(value: &Value) -> Result<(u64, String), String> {
    let count = value
        .get("byteCount")
        .and_then(Value::as_u64)
        .ok_or("Missing verifiable byte count")?;
    let hash = value
        .get("sha256")
        .and_then(Value::as_str)
        .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or("Missing verifiable SHA256; enable source mapping or a report when converting")?;
    Ok((count, hash.to_ascii_lowercase()))
}
pub(crate) fn reference(file: &OutputFile) -> Result<(PathBuf, PathBuf, u64, String), String> {
    let context = file.context.as_ref().ok_or("No output manifest")?;
    let path = PathBuf::from(
        context
            .get("outputDirectory")
            .and_then(Value::as_str)
            .ok_or("No output directory")?,
    );
    if !path.is_absolute() || !file.path.is_absolute() {
        return Err("Output paths must be absolute".into());
    }
    let relative = file
        .path
        .strip_prefix(&path)
        .map_err(|_| "Result is outside its output directory")?
        .to_path_buf();
    normal(&relative)?;
    let manifest = context
        .get("outputFiles")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find(|v| {
                v.get("path").and_then(Value::as_str).map(Path::new) == Some(relative.as_path())
            })
        })
        .ok_or(
            "No manifest entry for this result; enable source mapping or a report when converting",
        )?;
    let (count, hash) = fingerprint(manifest)?;
    Ok((path, relative, count, hash))
}
fn specification(file: &OutputFile) -> Result<(Arc<Root>, PathBuf, u64, String), String> {
    let (path, relative, count, hash) = reference(file)?;
    let context = file.context.as_ref().ok_or("No output manifest")?;
    let mut slot = context
        .root
        .lock()
        .map_err(|_| "Output binding unavailable")?;
    let root = if let Some(root) = slot.as_ref() {
        if root.path != path {
            return Err(err());
        }
        root.clone()
    } else {
        let directory = absolute_directory(&path)?;
        let m = directory.metadata().map_err(|e| e.to_string())?;
        let root = Arc::new(Root {
            path,
            directory,
            identity: (m.dev(), m.ino()),
        });
        *slot = Some(root.clone());
        root
    };
    root_current(&root)?;
    Ok((root, relative, count, hash))
}
pub(crate) fn stream(
    mut file: File,
    count: u64,
    hash: &str,
    capture: bool,
    cancel: &AtomicBool,
) -> Result<(Vec<u8>, Stamp), String> {
    let before = file.metadata().map_err(|e| e.to_string())?;
    if !before.is_file() || before.len() != count {
        return Err(err());
    }
    let before = Stamp::of(&before);
    let mut checksum =
        glib::Checksum::new(glib::ChecksumType::Sha256).ok_or("SHA256 unavailable")?;
    let mut data = Vec::new();
    let mut read = 0u64;
    let mut buffer = [0u8; 65536];
    while read <= count {
        if cancel.load(Ordering::Acquire) {
            return Err("Read cancelled".into());
        }
        let request =
            (count.saturating_sub(read).saturating_add(1)).min(buffer.len() as u64) as usize;
        let size = file
            .read(&mut buffer[..request])
            .map_err(|e| e.to_string())?;
        if size == 0 {
            break;
        }
        read += size as u64;
        checksum.update(&buffer[..size]);
        if capture {
            data.extend_from_slice(&buffer[..size]);
        }
    }
    if read != count
        || checksum.string().as_deref() != Some(hash)
        || Stamp::of(&file.metadata().map_err(|e| e.to_string())?) != before
    {
        return Err(err());
    }
    Ok((data, before))
}
pub(crate) fn read(
    file: &OutputFile,
    limit: u64,
    capture: bool,
    cancel: &AtomicBool,
) -> Result<Snapshot, String> {
    let (root, relative, count, hash) = specification(file)?;
    if count > limit {
        return Err(format!("Result exceeds read limit ({limit} bytes)"));
    }
    let (data, stamp) = stream(
        relative_file(&root.directory, &relative)?,
        count,
        &hash,
        capture,
        cancel,
    )?;
    let snapshot = Snapshot {
        data,
        root,
        relative,
        stamp,
    };
    revalidate(&snapshot)?;
    Ok(snapshot)
}
pub(crate) fn revalidate(snapshot: &Snapshot) -> Result<(), String> {
    root_current(&snapshot.root)?;
    let m = relative_file(&snapshot.root.directory, &snapshot.relative)?
        .metadata()
        .map_err(|e| e.to_string())?;
    if !m.is_file() || Stamp::of(&m) != snapshot.stamp {
        return Err(err());
    }
    Ok(())
}
pub(crate) fn text(file: &OutputFile, limit: u64) -> Result<String, String> {
    let snapshot = read(file, limit, true, &AtomicBool::new(false))?;
    String::from_utf8(snapshot.data).map_err(|_| "Result is not valid UTF-8".into())
}
pub(crate) fn source_file(path: &Path) -> Result<File, String> {
    let parent = path.parent().ok_or("Missing source parent")?;
    let name = path.file_name().ok_or("Missing source filename")?;
    openat(&absolute_directory(parent)?, name, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::symlink,
        time::{SystemTime, UNIX_EPOCH},
    };
    struct Fixture {
        root: PathBuf,
        file: OutputFile,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn fixture() -> Fixture {
        let root = std::env::temp_dir().join(format!(
            "pmt-read-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        let output = root.join("output");
        fs::create_dir(&output).unwrap();
        fs::create_dir(output.join("assets")).unwrap();
        fs::write(output.join("assets/é.md"), b"abc").unwrap();
        let value = serde_json::json!({"outputDirectory":output,"markdownFile":output.join("assets/é.md"),"outputFiles":[{"path":"assets/é.md","byteCount":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]});
        Fixture {
            root,
            file: crate::model::outputs(&value).remove(0),
        }
    }
    #[test]
    fn manifest_count_hash_and_bounded_read() {
        let f = fixture();
        assert_eq!(text(&f.file, 3).unwrap(), "abc");
        assert!(text(&f.file, 2).is_err());
        fs::write(&f.file.path, b"xyz").unwrap();
        assert!(text(&f.file, 3).is_err());
    }
    #[test]
    fn final_symlink_and_fifo_are_rejected_without_blocking() {
        let f = fixture();
        fs::remove_file(&f.file.path).unwrap();
        symlink("/etc/hosts", &f.file.path).unwrap();
        assert!(text(&f.file, 3).is_err());
        fs::remove_file(&f.file.path).unwrap();
        let name = CString::new(f.file.path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        let start = std::time::Instant::now();
        assert!(text(&f.file, 3).is_err());
        assert!(start.elapsed() < std::time::Duration::from_secs(1));
    }
    #[test]
    fn intermediate_symlink_and_bound_root_replacement_are_rejected() {
        let f = fixture();
        assert_eq!(text(&f.file, 3).unwrap(), "abc");
        let output = f.root.join("output");
        fs::rename(&output, f.root.join("original")).unwrap();
        let foreign = f.root.join("foreign");
        fs::create_dir(&foreign).unwrap();
        fs::create_dir(foreign.join("assets")).unwrap();
        fs::write(foreign.join("assets/é.md"), b"abc").unwrap();
        symlink(&foreign, &output).unwrap();
        assert!(text(&f.file, 3).is_err());
        assert_eq!(fs::read(foreign.join("assets/é.md")).unwrap(), b"abc");
        fs::remove_file(&output).unwrap();
        fs::rename(f.root.join("original"), &output).unwrap();
        fs::rename(output.join("assets"), output.join("oldassets")).unwrap();
        symlink(foreign.join("assets"), output.join("assets")).unwrap();
        assert!(text(&f.file, 3).is_err());
    }
    #[test]
    fn outside_and_parent_components_and_missing_manifest_are_rejected() {
        let f = fixture();
        let mut file = f.file.clone();
        file.path = f.root.join("foreign");
        assert!(text(&file, 3).is_err());
        file.path = f.root.join("output/assets/../assets/é.md");
        assert!(text(&file, 3).is_err());
        file = f.file.clone();
        file.context = None;
        assert!(text(&file, 3).is_err());
    }
    #[test]
    fn same_bytes_replaced_inode_invalidates_snapshot() {
        let f = fixture();
        let checked = read(&f.file, 3, true, &AtomicBool::new(false)).unwrap();
        fs::rename(&f.file.path, f.root.join("old")).unwrap();
        fs::write(&f.file.path, b"abc").unwrap();
        assert!(revalidate(&checked).is_err());
    }
    #[test]
    fn canonical_equivalent_names_are_distinct() {
        let f = fixture();
        let decomposed = f.root.join("output/assets/e\u{301}.md");
        fs::write(&decomposed, b"xyz").unwrap();
        let mut file = f.file.clone();
        file.path = decomposed;
        assert!(text(&file, 3).is_err());
        assert_eq!(text(&f.file, 3).unwrap(), "abc");
    }
}
