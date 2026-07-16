use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub fn default_token_path() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("herdr-remote-keypad")
        .join("token"))
}

pub fn initialize(path: &Path) -> Result<bool, String> {
    if path.exists() {
        read(path)?;
        return Ok(false);
    }

    let parent = path.parent().ok_or("token path has no parent directory")?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;

    let mut random = [0_u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut random))
        .map_err(|error| format!("could not read secure randomness: {error}"))?;
    let token = random
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();

    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| error.to_string())?;
    writeln!(file, "{token}").map_err(|error| error.to_string())?;
    Ok(true)
}

pub fn read(path: &Path) -> Result<String, String> {
    let metadata = fs::metadata(path).map_err(|error| error.to_string())?;
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "token file {} must not be readable by group or other users",
            path.display()
        ));
    }

    let token = fs::read_to_string(path)
        .map_err(|error| error.to_string())?
        .trim()
        .to_owned();
    if token.len() != 64
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("token must contain exactly 64 lowercase hexadecimal characters".into());
    }
    Ok(token)
}

pub fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_path() -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!(
                "herdr-remote-keypad-{}-{unique}",
                std::process::id()
            ))
            .join("token")
    }

    #[test]
    fn creates_private_token_once() {
        let path = temporary_path();
        assert_eq!(initialize(&path), Ok(true));
        let first = read(&path).unwrap();
        assert_eq!(first.len(), 64);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(initialize(&path), Ok(false));
        assert_eq!(read(&path).unwrap(), first);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn comparison_checks_content_and_length() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
    }
}
