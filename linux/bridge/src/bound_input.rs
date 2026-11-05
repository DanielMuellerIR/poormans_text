//! Versiegelte Originalbytes, ausschließlich im privaten /dev des CLI-Jobs sichtbar.
use crate::{BridgeError, ErrorKind};
use std::{
    fs::{File, OpenOptions},
    io::{self, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::PathBuf,
    sync::Arc,
};

pub const MAXIMUM_INPUT_BYTES: usize = 64 * 1024 * 1024;
const REQUIRED_SEALS: libc::c_int =
    libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL;

#[derive(Clone, Debug)]
pub struct InputName(String);
impl InputName {
    pub fn new(name: &str) -> Result<Self, BridgeError> {
        if name.is_empty()
            || name.len() > 64
            || name.starts_with('.')
            || !name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
        {
            return Err(error("Invalid bound-input basename."));
        }
        Ok(Self(name.into()))
    }
}
#[derive(Clone, Debug)]
pub struct BoundInput {
    file: Arc<File>,
    name: InputName,
}
fn error(message: impl Into<String>) -> BridgeError {
    BridgeError::new(ErrorKind::Spawn, message)
}
impl BoundInput {
    pub fn new(bytes: &[u8], name: InputName) -> Result<Self, BridgeError> {
        if bytes.len() > MAXIMUM_INPUT_BYTES {
            return Err(error("Clipboard content exceeds 64 MiB."));
        }
        let fd = unsafe {
            libc::memfd_create(
                c"pmt-clipboard".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        };
        if fd < 0 {
            return Err(error(format!(
                "Sealed clipboard input is unavailable: {}",
                io::Error::last_os_error()
            )));
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(bytes).map_err(|e| error(e.to_string()))?;
        if unsafe { libc::fchmod(fd, 0o400) } != 0 {
            return Err(error(format!(
                "Clipboard permissions failed: {}",
                io::Error::last_os_error()
            )));
        }
        if unsafe { libc::fcntl(fd, libc::F_ADD_SEALS, REQUIRED_SEALS) } < 0 {
            return Err(error(format!(
                "Clipboard sealing failed: {}",
                io::Error::last_os_error()
            )));
        }
        let value = Self {
            file: Arc::new(file),
            name,
        };
        value.validate()?;
        Ok(value)
    }
    pub fn path(&self) -> PathBuf {
        PathBuf::from("/dev/pmt-input").join(&self.name.0)
    }
    fn validate(&self) -> Result<(), BridgeError> {
        let fd = self.file.as_raw_fd();
        let seals = unsafe { libc::fcntl(fd, libc::F_GET_SEALS) };
        let metadata = self.file.metadata().map_err(|e| error(e.to_string()))?;
        if seals < 0
            || seals & REQUIRED_SEALS != REQUIRED_SEALS
            || !metadata.is_file()
            || metadata.len() > MAXIMUM_INPUT_BYTES as u64
        {
            return Err(error("Bound input is not a bounded sealed regular file."));
        }
        Ok(())
    }
    /// Neu öffnen statt dup: Jeder Job braucht einen unabhängigen Leseoffset bei null.
    pub fn reader(&self) -> Result<File, BridgeError> {
        self.validate()?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC)
            .open(format!("/proc/self/fd/{}", self.file.as_raw_fd()))
            .map_err(|e| error(e.to_string()))?;
        let expected = self.file.metadata().map_err(|e| error(e.to_string()))?;
        let actual = file.metadata().map_err(|e| error(e.to_string()))?;
        if expected.dev() != actual.dev() || expected.ino() != actual.ino() {
            return Err(error("Bound input identity changed."));
        }
        Ok(file)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    #[test]
    fn sealed_bytes_and_independent_offsets() {
        let source =
            BoundInput::new(b"ORIGINAL", InputName::new("clipboard.html").unwrap()).unwrap();
        assert_eq!(
            unsafe { libc::pwrite(source.file.as_raw_fd(), b"X".as_ptr().cast(), 1, 0) },
            -1
        );
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
        for _ in 0..2 {
            let mut bytes = Vec::new();
            source.reader().unwrap().read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, b"ORIGINAL");
        }
    }
    #[test]
    fn unsealed_input_is_rejected() {
        let fd = unsafe {
            libc::memfd_create(
                c"unsealed-test".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        };
        assert!(fd >= 0);
        let source = BoundInput {
            file: Arc::new(unsafe { File::from_raw_fd(fd) }),
            name: InputName::new("clipboard.png").unwrap(),
        };
        assert!(source.reader().is_err());
    }
    #[test]
    fn basename_and_size_fail_closed() {
        for name in [
            "",
            ".",
            "..",
            "../source.png",
            "/tmp/source.png",
            "x/y",
            "x\0y",
            "xé.png",
        ] {
            assert!(InputName::new(name).is_err());
        }
        assert!(BoundInput::new(
            &vec![0; MAXIMUM_INPUT_BYTES + 1],
            InputName::new("clipboard.png").unwrap()
        )
        .is_err());
    }
}
