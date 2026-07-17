use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const PAIRING_LIFETIME_SECS: u64 = 10 * 60;
const MAX_PAIRING_ATTEMPTS: u8 = 5;

pub struct DeviceStore {
    state_dir: PathBuf,
}

#[derive(Deserialize, Serialize)]
struct Pairing {
    code_sha256: String,
    expires_at: u64,
    failed_attempts: u8,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub paired_at: u64,
    credential_sha256: String,
}

#[derive(Debug)]
pub struct PairedDevice {
    pub device_id: String,
    pub credential: String,
}

impl DeviceStore {
    pub fn new(state_dir: PathBuf) -> Self {
        Self { state_dir }
    }

    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }

    pub fn initialize(&self) -> Result<(), String> {
        private_directory(&self.state_dir)?;
        private_directory(&self.devices_dir())
    }

    pub fn create_pairing(&self) -> Result<String, String> {
        self.initialize()?;
        let _lock = self.lock_pairing()?;
        let code = random_pairing_code()?;
        let pairing = Pairing {
            code_sha256: sha256_hex(code.as_bytes()),
            expires_at: now()?.saturating_add(PAIRING_LIFETIME_SECS),
            failed_attempts: 0,
        };
        write_private_json(&self.pairing_path(), &pairing, false)?;
        Ok(code)
    }

    pub fn pair(&self, code: &str, device_name: &str) -> Result<PairedDevice, String> {
        self.initialize()?;
        let _lock = self.lock_pairing()?;
        let name = sanitize_device_name(device_name)?;
        let path = self.pairing_path();
        let mut pairing: Pairing = read_private_json(&path)
            .map_err(|_| "pairing failed; run 'agentslate pair' for a new code".to_owned())?;

        if now()? >= pairing.expires_at {
            let _ = fs::remove_file(&path);
            return Err("pairing failed; run 'agentslate pair' for a new code".into());
        }
        if validate_pairing_code(code).is_err()
            || !constant_time_eq(
                pairing.code_sha256.as_bytes(),
                sha256_hex(code.as_bytes()).as_bytes(),
            )
        {
            pairing.failed_attempts = pairing.failed_attempts.saturating_add(1);
            if pairing.failed_attempts >= MAX_PAIRING_ATTEMPTS {
                let _ = fs::remove_file(&path);
            } else {
                write_private_json(&path, &pairing, false)?;
            }
            return Err("pairing failed; run 'agentslate pair' for a new code".into());
        }

        let device_id = random_hex(16)?;
        let credential = random_hex(32)?;
        let device = Device {
            id: device_id.clone(),
            name,
            paired_at: now()?,
            credential_sha256: sha256_hex(credential.as_bytes()),
        };
        write_private_json(&self.device_path(&device_id)?, &device, true)?;
        if let Err(error) = fs::remove_file(path) {
            let _ = fs::remove_file(self.device_path(&device_id)?);
            return Err(format!("could not consume pairing code: {error}"));
        }
        Ok(PairedDevice {
            device_id,
            credential,
        })
    }

    pub fn authenticate(&self, device_id: &str, credential: &str) -> bool {
        if validate_credential(credential).is_err() {
            return false;
        }
        let Ok(path) = self.device_path(device_id) else {
            return false;
        };
        let Ok(device) = read_private_json::<Device>(&path) else {
            return false;
        };
        constant_time_eq(
            device.credential_sha256.as_bytes(),
            sha256_hex(credential.as_bytes()).as_bytes(),
        )
    }

    pub fn list(&self) -> Result<Vec<Device>, String> {
        self.initialize()?;
        let mut devices = Vec::<Device>::new();
        for entry in fs::read_dir(self.devices_dir()).map_err(|error| error.to_string())? {
            let path = entry.map_err(|error| error.to_string())?.path();
            if path.extension().and_then(|value| value.to_str()) == Some("json") {
                devices.push(read_private_json(&path)?);
            }
        }
        devices.sort_by_key(|device| device.paired_at);
        Ok(devices)
    }

    pub fn revoke(&self, device_id: &str) -> Result<bool, String> {
        let path = self.device_path(device_id)?;
        match fs::remove_file(path) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.to_string()),
        }
    }

    fn devices_dir(&self) -> PathBuf {
        self.state_dir.join("devices")
    }

    fn pairing_path(&self) -> PathBuf {
        self.state_dir.join("pairing.json")
    }

    fn lock_pairing(&self) -> Result<File, String> {
        let path = self.state_dir.join("pairing.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(path)
            .map_err(|error| error.to_string())?;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
        file.lock_exclusive().map_err(|error| error.to_string())?;
        Ok(file)
    }

    fn device_path(&self, device_id: &str) -> Result<PathBuf, String> {
        validate_device_id(device_id)?;
        Ok(self.devices_dir().join(format!("{device_id}.json")))
    }
}

pub fn default_state_dir() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home).join(".config").join("agentslate"))
}

fn private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|error| error.to_string())?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| error.to_string())
}

fn write_private_json<T: Serialize>(
    path: &Path,
    value: &T,
    create_new: bool,
) -> Result<(), String> {
    let parent = path.parent().ok_or("state file has no parent directory")?;
    private_directory(parent)?;
    let mut options = OpenOptions::new();
    options.write(true).mode(0o600);
    if create_new {
        options.create_new(true);
    } else {
        options.create(true).truncate(true);
    }
    let mut file = options.open(path).map_err(|error| error.to_string())?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())?;
    serde_json::to_writer(&mut file, value).map_err(|error| error.to_string())?;
    file.write_all(b"\n").map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())
}

fn read_private_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, String> {
    let metadata = fs::metadata(path).map_err(|error| error.to_string())?;
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "{} must not be accessible by group or other users",
            path.display()
        ));
    }
    serde_json::from_reader(File::open(path).map_err(|error| error.to_string())?)
        .map_err(|error| error.to_string())
}

fn random_pairing_code() -> Result<String, String> {
    let limit = u32::MAX - (u32::MAX % 1_000_000);
    loop {
        let mut bytes = [0_u8; 4];
        secure_random(&mut bytes)?;
        let value = u32::from_ne_bytes(bytes);
        if value < limit {
            return Ok(format!("{:06}", value % 1_000_000));
        }
    }
}

fn random_hex(bytes: usize) -> Result<String, String> {
    let mut random = vec![0_u8; bytes];
    secure_random(&mut random)?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn secure_random(bytes: &mut [u8]) -> Result<(), String> {
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(bytes))
        .map_err(|error| format!("could not read secure randomness: {error}"))
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn now() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|error| error.to_string())
}

fn sanitize_device_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 100 || name.chars().any(char::is_control) {
        return Err("device_name must be 1-100 characters without control characters".into());
    }
    Ok(name.to_owned())
}

fn validate_pairing_code(code: &str) -> Result<(), String> {
    if code.len() == 6 && code.bytes().all(|byte| byte.is_ascii_digit()) {
        Ok(())
    } else {
        Err("pairing code must contain exactly 6 digits".into())
    }
}

fn validate_device_id(device_id: &str) -> Result<(), String> {
    validate_lower_hex(device_id, 32, "device_id")
}

fn validate_credential(credential: &str) -> Result<(), String> {
    validate_lower_hex(credential, 64, "credential")
}

fn validate_lower_hex(value: &str, length: usize, field: &str) -> Result<(), String> {
    if value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(format!(
            "{field} must contain exactly {length} lowercase hexadecimal characters"
        ))
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    for index in 0..left.len().max(right.len()) {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_ID: AtomicU64 = AtomicU64::new(1);

    fn store() -> DeviceStore {
        DeviceStore::new(std::env::temp_dir().join(format!(
            "agentslate-device-test-{}-{}",
            std::process::id(),
            TEST_ID.fetch_add(1, Ordering::Relaxed)
        )))
    }

    #[test]
    fn pairing_is_single_use_and_stores_only_the_credential_digest() {
        let store = store();
        let code = store.create_pairing().unwrap();
        assert_eq!(code.len(), 6);
        let paired = store.pair(&code, " Daniel's iPhone ").unwrap();
        assert_eq!(paired.device_id.len(), 32);
        assert_eq!(paired.credential.len(), 64);
        assert!(store.authenticate(&paired.device_id, &paired.credential));
        assert!(!store.authenticate(&paired.device_id, &"0".repeat(64)));
        assert!(store.pair(&code, "Second phone").is_err());

        let stored = fs::read_to_string(store.device_path(&paired.device_id).unwrap()).unwrap();
        assert!(!stored.contains(&paired.credential));
        assert_eq!(
            fs::metadata(store.device_path(&paired.device_id).unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_dir_all(store.state_dir()).unwrap();
    }

    #[test]
    fn fifth_bad_attempt_invalidates_the_code_and_revocation_is_immediate() {
        let store = store();
        let code = store.create_pairing().unwrap();
        let wrong = if code == "000000" { "000001" } else { "000000" };
        for _ in 0..4 {
            assert!(store.pair(wrong, "Phone").is_err());
        }
        assert!(store.pair("bad", "Phone").is_err());
        assert!(store.pair(&code, "Phone").is_err());

        let code = store.create_pairing().unwrap();
        let paired = store.pair(&code, "Phone").unwrap();
        assert!(store.revoke(&paired.device_id).unwrap());
        assert!(!store.authenticate(&paired.device_id, &paired.credential));
        assert!(!store.revoke(&paired.device_id).unwrap());
        fs::remove_dir_all(store.state_dir()).unwrap();
    }

    #[test]
    fn failed_pairing_attempts_are_serialized_across_store_instances() {
        let store = store();
        let code = store.create_pairing().unwrap();
        let wrong = if code == "000000" { "000001" } else { "000000" };
        let state_dir = store.state_dir().to_owned();
        let attempts = (0..5)
            .map(|_| {
                let state_dir = state_dir.clone();
                std::thread::spawn(move || {
                    DeviceStore::new(state_dir).pair(wrong, "Concurrent phone")
                })
            })
            .collect::<Vec<_>>();
        for attempt in attempts {
            assert!(attempt.join().unwrap().is_err());
        }
        assert!(store.pair(&code, "Phone").is_err());
        assert!(!store.pairing_path().exists());
        fs::remove_dir_all(store.state_dir()).unwrap();
    }

    #[test]
    fn expired_pairing_is_rejected() {
        let store = store();
        store.initialize().unwrap();
        write_private_json(
            &store.pairing_path(),
            &Pairing {
                code_sha256: sha256_hex(b"123456"),
                expires_at: 0,
                failed_attempts: 0,
            },
            false,
        )
        .unwrap();
        assert!(store.pair("123456", "Phone").is_err());
        assert!(!store.pairing_path().exists());
        fs::remove_dir_all(store.state_dir()).unwrap();
    }
}
