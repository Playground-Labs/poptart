//! Provider API keys stored in the operating system credential facility.
//!
//! `keyring` maps to Keychain Services on macOS, Credential Manager on
//! Windows, and Secret Service on Linux. If a platform has no usable secure
//! store, new credentials are refused and a legacy serialized key remains in
//! place until migration can succeed.

use std::collections::HashMap;

const SERVICE: &str = "com.bkwilcox.poptart.post-processing";

trait CredentialBackend {
    fn set(&self, provider_id: &str, secret: &str) -> Result<(), String>;
    fn get(&self, provider_id: &str) -> Result<Option<String>, String>;
    fn remove(&self, provider_id: &str) -> Result<(), String>;
}

struct OsCredentialBackend;

impl OsCredentialBackend {
    fn entry(provider_id: &str) -> Result<keyring::Entry, String> {
        keyring::Entry::new(SERVICE, provider_id)
            .map_err(|_| "the operating system credential store is unavailable".to_string())
    }
}

impl CredentialBackend for OsCredentialBackend {
    fn set(&self, provider_id: &str, secret: &str) -> Result<(), String> {
        Self::entry(provider_id)?
            .set_password(secret)
            .map_err(|_| "the operating system refused to store the credential".to_string())
    }

    fn get(&self, provider_id: &str) -> Result<Option<String>, String> {
        match Self::entry(provider_id)?.get_password() {
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err("the operating system refused to read the credential".to_string()),
        }
    }

    fn remove(&self, provider_id: &str) -> Result<(), String> {
        let entry = Self::entry(provider_id)?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err("the operating system refused to remove the credential".to_string()),
        }
    }
}

pub(crate) fn set(provider_id: &str, secret: &str) -> Result<(), String> {
    if secret.is_empty() {
        OsCredentialBackend.remove(provider_id)
    } else {
        OsCredentialBackend.set(provider_id, secret)
    }
}

pub(crate) fn get(provider_id: &str) -> Result<Option<String>, String> {
    OsCredentialBackend.get(provider_id)
}

pub(crate) fn resolve(provider_id: &str, legacy_value: Option<&String>) -> String {
    get(provider_id)
        .ok()
        .flatten()
        .or_else(|| legacy_value.filter(|value| !value.is_empty()).cloned())
        .unwrap_or_default()
}

pub(crate) fn configured(provider_id: &str, legacy_value: Option<&String>) -> bool {
    legacy_value.is_some_and(|value| !value.is_empty()) || get(provider_id).ok().flatten().is_some()
}

fn migrate_with(
    backend: &impl CredentialBackend,
    legacy: &mut HashMap<String, String>,
) -> (bool, Vec<String>) {
    let mut changed = false;
    let mut failures = Vec::new();
    for (provider_id, secret) in legacy.iter_mut() {
        if secret.is_empty() {
            continue;
        }
        match backend.set(provider_id, secret) {
            Ok(()) => {
                secret.clear();
                changed = true;
            }
            Err(_) => failures.push(provider_id.clone()),
        }
    }
    (changed, failures)
}

pub(crate) fn migrate_legacy(legacy: &mut HashMap<String, String>) -> bool {
    let (changed, failures) = migrate_with(&OsCredentialBackend, legacy);
    for provider_id in failures {
        log::warn!(
            "Could not migrate the '{}' provider credential to secure storage; retaining the legacy value",
            provider_id
        );
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::{migrate_with, CredentialBackend};
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct MemoryBackend {
        values: Mutex<HashMap<String, String>>,
        fail_writes: bool,
    }

    impl CredentialBackend for MemoryBackend {
        fn set(&self, provider_id: &str, secret: &str) -> Result<(), String> {
            if self.fail_writes {
                return Err("failed".to_string());
            }
            self.values
                .lock()
                .unwrap()
                .insert(provider_id.to_string(), secret.to_string());
            Ok(())
        }

        fn get(&self, provider_id: &str) -> Result<Option<String>, String> {
            Ok(self.values.lock().unwrap().get(provider_id).cloned())
        }

        fn remove(&self, provider_id: &str) -> Result<(), String> {
            self.values.lock().unwrap().remove(provider_id);
            Ok(())
        }
    }

    #[test]
    fn successful_migration_clears_serialized_secret_after_secure_write() {
        let backend = MemoryBackend::default();
        let mut legacy = HashMap::from([("openai".to_string(), "secret".to_string())]);
        let (changed, failures) = migrate_with(&backend, &mut legacy);
        assert!(changed);
        assert!(failures.is_empty());
        assert_eq!(legacy["openai"], "");
        assert_eq!(backend.get("openai").unwrap().as_deref(), Some("secret"));
    }

    #[test]
    fn failed_migration_preserves_the_working_legacy_secret() {
        let backend = MemoryBackend {
            fail_writes: true,
            ..Default::default()
        };
        let mut legacy = HashMap::from([("openai".to_string(), "secret".to_string())]);
        let (changed, failures) = migrate_with(&backend, &mut legacy);
        assert!(!changed);
        assert_eq!(failures, ["openai"]);
        assert_eq!(legacy["openai"], "secret");
    }

    #[test]
    fn credentials_can_be_created_updated_and_removed() {
        let backend = MemoryBackend::default();
        backend.set("openai", "first").unwrap();
        assert_eq!(backend.get("openai").unwrap().as_deref(), Some("first"));
        backend.set("openai", "second").unwrap();
        assert_eq!(backend.get("openai").unwrap().as_deref(), Some("second"));
        backend.remove("openai").unwrap();
        assert_eq!(backend.get("openai").unwrap(), None);
    }
}
