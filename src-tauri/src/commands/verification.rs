//! Tauri-facing verification adapter.
//!
//! This module deliberately has no command accepting a receipt, key, readiness value, or
//! report. Such values are driver/app-private protocol data and must never cross Tauri IPC.

use std::{
    io::{BufRead, Write},
    sync::Mutex,
};

use crate::verification::{DriverBootstrapV1, ReceiptCommand, ReceiptOutcome, VerificationSession};

pub struct VerificationTransport {
    session: Mutex<Option<VerificationSession>>,
}

impl VerificationTransport {
    pub fn disabled() -> Self {
        Self {
            session: Mutex::new(None),
        }
    }

    /// Native bootstrap only. It is not a Tauri command and accepts no user-controlled data.
    pub fn install_from_driver(&self, session: VerificationSession) -> Result<(), &'static str> {
        let mut guard = self
            .session
            .lock()
            .map_err(|_| "verification transport poisoned")?;
        if guard.is_some() {
            return Err("verification transport is one-shot");
        }
        *guard = Some(session);
        Ok(())
    }

    pub fn is_driver_owned(&self) -> bool {
        self.session.lock().is_ok_and(|guard| guard.is_some())
    }

    /// Emits a content-free frame only when the reviewed driver supplied the inherited
    /// bootstrap.  The caller supplies native digests, never UI-provided proof fields.
    pub fn record(
        &self,
        command: ReceiptCommand,
        input_sha256: String,
        outcome: ReceiptOutcome,
        before_state_sha256: String,
        after_state_sha256: String,
        provenance_sha256: String,
    ) {
        let Ok(mut guard) = self.session.lock() else {
            return;
        };
        let Some(session) = guard.as_mut() else {
            return;
        };
        let Ok(receipt) = session.issue(
            command,
            input_sha256,
            outcome,
            before_state_sha256,
            after_state_sha256,
            provenance_sha256,
        ) else {
            return;
        };
        // stdout is the child end of the driver's private inherited pipe. It is never a
        // PowerShell receipt handle. A write failure leaves the driver without a receipt.
        if let Ok(encoded) = serde_json::to_string(&receipt) {
            let _ = writeln!(std::io::stdout(), "{encoded}");
        }
    }

    /// Called before Tauri starts. Normal desktop launches do not have a pipe stdin and stay
    /// disabled. A malformed driver bootstrap also fails closed by leaving the transport off.
    #[cfg(windows)]
    pub fn from_inherited_driver() -> Self {
        const STD_INPUT_HANDLE: u32 = u32::MAX - 10;
        const FILE_TYPE_PIPE: u32 = 3;
        extern "system" {
            fn GetStdHandle(n_std_handle: u32) -> *mut std::ffi::c_void;
            fn GetFileType(handle: *mut std::ffi::c_void) -> u32;
        }
        let handle = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        if handle.is_null() || unsafe { GetFileType(handle) } != FILE_TYPE_PIPE {
            return Self::disabled();
        }
        let mut line = String::new();
        if std::io::stdin()
            .lock()
            .read_line(&mut line)
            .ok()
            .filter(|count| *count <= 8192 && *count > 0)
            .is_none()
        {
            return Self::disabled();
        }
        let Ok(bootstrap) = serde_json::from_str::<DriverBootstrapV1>(&line) else {
            return Self::disabled();
        };
        let Ok(session) = VerificationSession::from_driver_bootstrap(bootstrap) else {
            return Self::disabled();
        };
        Self {
            session: Mutex::new(Some(session)),
        }
    }

    #[cfg(not(windows))]
    pub fn from_inherited_driver() -> Self {
        Self::disabled()
    }
}

#[tauri::command]
pub fn verification_transport_status(transport: tauri::State<VerificationTransport>) -> bool {
    transport.is_driver_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    fn hash(value: &str) -> String {
        Sha256::digest(value.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
    #[test]
    fn native_transport_is_one_shot_and_has_no_ipc_import() {
        let transport = VerificationTransport::disabled();
        let session = VerificationSession::new_for_driver(
            "run".into(),
            [1; 32],
            [2; 32],
            hash("app"),
            hash("driver"),
        )
        .unwrap();
        assert!(transport.install_from_driver(session).is_ok());
        assert!(transport.is_driver_owned());
    }
}
