//! Target-PC verification protocol.
//!
//! The durable report deliberately contains digests and typed outcomes only.  It is an
//! audit record for the reviewed launcher/driver/app trio, not proof against a same-user
//! attacker who can replace that trio, read its memory, inject/debug either process, or
//! rewrite a report after it is written.  Code signing or a hardware-backed root of trust
//! is required for that stronger claim.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const PROTOCOL_VERSION: u8 = 1;
pub const SESSION_KEY_BYTES: usize = 32;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Phase1TargetInputsV1 {
    pub schema_version: u8,
    pub input_endpoint_id: String,
    pub loopback_endpoint_id: String,
    pub model_path: String,
    #[serde(default)]
    pub available_accelerators: Vec<Accelerator>,
}

impl Phase1TargetInputsV1 {
    pub fn validate(&self) -> Result<(), VerificationError> {
        if self.schema_version != PROTOCOL_VERSION {
            return Err(VerificationError::InvalidInput(
                "unsupported schema version",
            ));
        }
        if self.input_endpoint_id.trim().is_empty()
            || self.loopback_endpoint_id.trim().is_empty()
            || self.model_path.trim().is_empty()
        {
            return Err(VerificationError::InvalidInput(
                "required operational selection is blank",
            ));
        }
        if self
            .available_accelerators
            .iter()
            .any(|value| *value == Accelerator::Cpu)
        {
            return Err(VerificationError::InvalidInput(
                "CPU is implicit and cannot be requested",
            ));
        }
        Ok(())
    }

    /// Never persist these values.  The separator preserves the endpoint kind boundary.
    pub fn input_digest(&self) -> String {
        digest_text(&format!("input\0{}", self.input_endpoint_id))
    }

    pub fn loopback_digest(&self) -> String {
        digest_text(&format!("render-loopback\0{}", self.loopback_endpoint_id))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Accelerator {
    Cuda,
    Vulkan,
    Cpu,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReceiptCommand {
    InputSelection,
    RenderLoopbackSelection,
    CaptureSignal,
    CaptureLoss,
    CpuFixture,
    AcceleratorFixture,
    BenchmarkProfile,
    PcmCleanup,
    OfficialSource,
    OfficialCaption,
    SetupCommit,
    RestartValidation,
    DriftConfirmation,
    FinalReady,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReceiptOutcome {
    Affirmative,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeCommandReceiptV1 {
    pub protocol_version: u8,
    pub run_id: String,
    pub challenge_sha256: String,
    pub sequence: u32,
    pub command: ReceiptCommand,
    pub input_sha256: String,
    pub outcome: ReceiptOutcome,
    pub before_state_sha256: String,
    pub after_state_sha256: String,
    pub timestamp_unix_ms: u128,
    pub previous_receipt_sha256: String,
    pub trusted_app_sha256: String,
    pub trusted_driver_sha256: String,
    pub provenance_sha256: String,
    pub receipt_sha256: String,
    pub receipt_hmac_sha256: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RedactedTargetReportV1 {
    pub schema_version: u8,
    pub run_id: String,
    pub trusted_app_sha256: String,
    pub trusted_driver_sha256: String,
    pub input_endpoint_sha256: String,
    pub loopback_endpoint_sha256: String,
    pub receipt_count: u32,
    pub final_receipt_sha256: String,
    pub native_authenticated: bool,
    pub final_ready: bool,
    pub trust_boundary: &'static str,
}

#[derive(Clone, Debug)]
pub struct VerificationSession {
    run_id: String,
    challenge: [u8; SESSION_KEY_BYTES],
    key: [u8; SESSION_KEY_BYTES],
    trusted_app_sha256: String,
    trusted_driver_sha256: String,
    previous_receipt_sha256: String,
    sequence: u32,
}

/// Ephemeral driver-to-app bootstrap. This travels only over the inherited child stdin;
/// it is neither an IPC argument nor a durable report/evidence format.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DriverBootstrapV1 {
    pub protocol_version: u8,
    pub run_id: String,
    pub challenge: [u8; SESSION_KEY_BYTES],
    pub session_key: [u8; SESSION_KEY_BYTES],
    pub trusted_app_sha256: String,
    pub trusted_driver_sha256: String,
}

impl Drop for VerificationSession {
    fn drop(&mut self) {
        self.key.fill(0);
        self.challenge.fill(0);
    }
}

impl VerificationSession {
    /// Production callers must use `new_cng`; tests may use this constructor with their
    /// driver-owned fixed bytes.  There is intentionally no deserialization path for a key.
    pub fn new_for_driver(
        run_id: String,
        challenge: [u8; SESSION_KEY_BYTES],
        key: [u8; SESSION_KEY_BYTES],
        trusted_app_sha256: String,
        trusted_driver_sha256: String,
    ) -> Result<Self, VerificationError> {
        validate_hash(&trusted_app_sha256)?;
        validate_hash(&trusted_driver_sha256)?;
        if run_id.is_empty() {
            return Err(VerificationError::InvalidInput("empty run id"));
        }
        Ok(Self {
            run_id,
            challenge,
            key,
            trusted_app_sha256,
            trusted_driver_sha256,
            previous_receipt_sha256: "0".repeat(64),
            sequence: 0,
        })
    }

    #[cfg(windows)]
    pub fn new_cng(
        trusted_app_sha256: String,
        trusted_driver_sha256: String,
    ) -> Result<Self, VerificationError> {
        let mut random = [0u8; SESSION_KEY_BYTES * 2];
        // BCryptGenRandom is the Windows CNG system-preferred RNG.  The session key never
        // enters PowerShell and is subsequently zeroed by Drop.
        let status = unsafe {
            bcrypt_gen_random(
                std::ptr::null_mut(),
                random.as_mut_ptr(),
                random.len() as u32,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG,
            )
        };
        if status < 0 {
            return Err(VerificationError::Randomness);
        }
        let mut challenge = [0u8; SESSION_KEY_BYTES];
        let mut key = [0u8; SESSION_KEY_BYTES];
        challenge.copy_from_slice(&random[..SESSION_KEY_BYTES]);
        key.copy_from_slice(&random[SESSION_KEY_BYTES..]);
        random.fill(0);
        Self::new_for_driver(
            format!("{:x}", Sha256::digest(challenge)),
            challenge,
            key,
            trusted_app_sha256,
            trusted_driver_sha256,
        )
    }

    pub fn challenge_sha256(&self) -> String {
        hex(&Sha256::digest(self.challenge))
    }
    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn bootstrap(&self) -> DriverBootstrapV1 {
        DriverBootstrapV1 {
            protocol_version: PROTOCOL_VERSION,
            run_id: self.run_id.clone(),
            challenge: self.challenge,
            session_key: self.key,
            trusted_app_sha256: self.trusted_app_sha256.clone(),
            trusted_driver_sha256: self.trusted_driver_sha256.clone(),
        }
    }
    pub fn from_driver_bootstrap(bootstrap: DriverBootstrapV1) -> Result<Self, VerificationError> {
        if bootstrap.protocol_version != PROTOCOL_VERSION {
            return Err(VerificationError::SessionMismatch);
        }
        Self::new_for_driver(
            bootstrap.run_id,
            bootstrap.challenge,
            bootstrap.session_key,
            bootstrap.trusted_app_sha256,
            bootstrap.trusted_driver_sha256,
        )
    }

    pub fn issue(
        &mut self,
        command: ReceiptCommand,
        input_sha256: String,
        outcome: ReceiptOutcome,
        before_state_sha256: String,
        after_state_sha256: String,
        provenance_sha256: String,
    ) -> Result<NativeCommandReceiptV1, VerificationError> {
        validate_hash(&input_sha256)?;
        validate_hash(&before_state_sha256)?;
        validate_hash(&after_state_sha256)?;
        validate_hash(&provenance_sha256)?;
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(VerificationError::Sequence)?;
        let timestamp_unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| VerificationError::Clock)?
            .as_millis();
        let mut receipt = NativeCommandReceiptV1 {
            protocol_version: PROTOCOL_VERSION,
            run_id: self.run_id.clone(),
            challenge_sha256: self.challenge_sha256(),
            sequence: self.sequence,
            command,
            input_sha256,
            outcome,
            before_state_sha256,
            after_state_sha256,
            timestamp_unix_ms,
            previous_receipt_sha256: self.previous_receipt_sha256.clone(),
            trusted_app_sha256: self.trusted_app_sha256.clone(),
            trusted_driver_sha256: self.trusted_driver_sha256.clone(),
            provenance_sha256,
            receipt_sha256: String::new(),
            receipt_hmac_sha256: String::new(),
        };
        receipt.receipt_sha256 = digest_bytes(&canonical_receipt(&receipt));
        receipt.receipt_hmac_sha256 = hmac_sha256_hex(&self.key, &authenticated_frame(&receipt));
        self.previous_receipt_sha256 = receipt.receipt_sha256.clone();
        Ok(receipt)
    }

    pub fn verify(&self, receipt: &NativeCommandReceiptV1) -> Result<(), VerificationError> {
        if receipt.protocol_version != PROTOCOL_VERSION
            || receipt.run_id != self.run_id
            || receipt.challenge_sha256 != self.challenge_sha256()
        {
            return Err(VerificationError::SessionMismatch);
        }
        if receipt.sequence == 0 || receipt.sequence > self.sequence {
            return Err(VerificationError::Sequence);
        }
        validate_hash(&receipt.receipt_sha256)?;
        if receipt.receipt_sha256 != digest_bytes(&canonical_receipt(receipt)) {
            return Err(VerificationError::Digest);
        }
        if !constant_time_equal(
            receipt.receipt_hmac_sha256.as_bytes(),
            hmac_sha256_hex(&self.key, &authenticated_frame(receipt)).as_bytes(),
        ) {
            return Err(VerificationError::Authentication);
        }
        Ok(())
    }

    pub fn report(
        &self,
        inputs: &Phase1TargetInputsV1,
        receipts: &[NativeCommandReceiptV1],
    ) -> Result<RedactedTargetReportV1, VerificationError> {
        inputs.validate()?;
        let mut previous = "0".repeat(64);
        for (index, receipt) in receipts.iter().enumerate() {
            self.verify(receipt)?;
            if receipt.sequence != (index + 1) as u32
                || receipt.previous_receipt_sha256 != previous
                || receipt.outcome != ReceiptOutcome::Affirmative
            {
                return Err(VerificationError::Incomplete);
            }
            previous = receipt.receipt_sha256.clone();
        }
        let required = required_commands(&inputs.available_accelerators);
        if receipts
            .iter()
            .map(|receipt| receipt.command)
            .collect::<Vec<_>>()
            != required
        {
            return Err(VerificationError::Incomplete);
        }
        Ok(RedactedTargetReportV1 {
            schema_version: PROTOCOL_VERSION, run_id: self.run_id.clone(), trusted_app_sha256: self.trusted_app_sha256.clone(), trusted_driver_sha256: self.trusted_driver_sha256.clone(),
            input_endpoint_sha256: inputs.input_digest(), loopback_endpoint_sha256: inputs.loopback_digest(), receipt_count: receipts.len() as u32,
            final_receipt_sha256: previous, native_authenticated: true, final_ready: true,
            trust_boundary: "Reviewed launcher, pinned driver/app, and unchanged probes prevent request/file fabrication; not tamperproof against same-user trusted-code replacement, memory inspection, injection/debugging, or post-run report editing.",
        })
    }
}

fn required_commands(accelerators: &[Accelerator]) -> Vec<ReceiptCommand> {
    let mut required = vec![
        ReceiptCommand::InputSelection,
        ReceiptCommand::RenderLoopbackSelection,
        ReceiptCommand::CaptureSignal,
        ReceiptCommand::CaptureLoss,
        ReceiptCommand::CpuFixture,
    ];
    required.extend(
        accelerators
            .iter()
            .map(|_| ReceiptCommand::AcceleratorFixture),
    );
    required.extend([
        ReceiptCommand::BenchmarkProfile,
        ReceiptCommand::PcmCleanup,
        ReceiptCommand::OfficialSource,
        ReceiptCommand::OfficialCaption,
        ReceiptCommand::SetupCommit,
        ReceiptCommand::RestartValidation,
        ReceiptCommand::DriftConfirmation,
        ReceiptCommand::FinalReady,
    ]);
    required
}

fn canonical_receipt(receipt: &NativeCommandReceiptV1) -> Vec<u8> {
    format!(
        "v{}\0{}\0{}\0{}\0{:?}\0{}\0{:?}\0{}\0{}\0{}\0{}\0{}\0{}\0{}",
        receipt.protocol_version,
        receipt.run_id,
        receipt.challenge_sha256,
        receipt.sequence,
        receipt.command,
        receipt.input_sha256,
        receipt.outcome,
        receipt.before_state_sha256,
        receipt.after_state_sha256,
        receipt.timestamp_unix_ms,
        receipt.previous_receipt_sha256,
        receipt.trusted_app_sha256,
        receipt.trusted_driver_sha256,
        receipt.provenance_sha256
    )
    .into_bytes()
}

fn authenticated_frame(receipt: &NativeCommandReceiptV1) -> Vec<u8> {
    canonical_receipt(receipt)
}
/// Hashes a native-only value before it crosses the receipt boundary.
pub fn digest_for_native(value: &str) -> String {
    digest_text(value)
}
fn digest_text(value: &str) -> String {
    digest_bytes(value.as_bytes())
}
fn digest_bytes(value: &[u8]) -> String {
    hex(&Sha256::digest(value))
}
fn validate_hash(value: &str) -> Result<(), VerificationError> {
    if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(VerificationError::InvalidInput("invalid sha256"))
    }
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

fn hmac_sha256_hex(key: &[u8; SESSION_KEY_BYTES], frame: &[u8]) -> String {
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for (index, byte) in key.iter().enumerate() {
        ipad[index] ^= byte;
        opad[index] ^= byte;
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(frame);
    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner.finalize());
    hex(&outer.finalize())
}

#[cfg(windows)]
const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x0000_0002;
#[cfg(windows)]
#[link(name = "bcrypt")]
extern "system" {
    #[link_name = "BCryptGenRandom"]
    fn bcrypt_gen_random(
        algorithm: *mut std::ffi::c_void,
        buffer: *mut u8,
        length: u32,
        flags: u32,
    ) -> i32;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerificationError {
    InvalidInput(&'static str),
    Randomness,
    Clock,
    Sequence,
    SessionMismatch,
    Digest,
    Authentication,
    Incomplete,
}
impl std::fmt::Display for VerificationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "verification failed: {self:?}")
    }
}
impl std::error::Error for VerificationError {}

#[cfg(test)]
mod tests {
    use super::*;
    fn hash(seed: &str) -> String {
        digest_text(seed)
    }
    fn session() -> VerificationSession {
        VerificationSession::new_for_driver(
            "driver-owned-run".into(),
            [7; 32],
            [9; 32],
            hash("app"),
            hash("driver"),
        )
        .unwrap()
    }
    fn inputs() -> Phase1TargetInputsV1 {
        Phase1TargetInputsV1 {
            schema_version: 1,
            input_endpoint_id: "input-a".into(),
            loopback_endpoint_id: "render-b".into(),
            model_path: "C:/model.bin".into(),
            available_accelerators: vec![],
        }
    }
    fn receipt(
        session: &mut VerificationSession,
        command: ReceiptCommand,
    ) -> NativeCommandReceiptV1 {
        session
            .issue(
                command,
                hash("input"),
                ReceiptOutcome::Affirmative,
                hash("before"),
                hash("after"),
                hash("provenance"),
            )
            .unwrap()
    }

    #[test]
    fn target_inputs_reject_proof_fields() {
        let value = r#"{\"schemaVersion\":1,\"inputEndpointId\":\"a\",\"loopbackEndpointId\":\"b\",\"modelPath\":\"m\",\"expectedAppSha256\":\"forbidden\"}"#;
        assert!(serde_json::from_str::<Phase1TargetInputsV1>(value).is_err());
        assert!(inputs().validate().is_ok());
    }
    #[test]
    fn mutated_or_rehashed_receipt_cannot_be_authenticated() {
        let mut session = session();
        let mut frame = receipt(&mut session, ReceiptCommand::InputSelection);
        frame.provenance_sha256 = hash("forged");
        frame.receipt_sha256 = digest_bytes(&canonical_receipt(&frame));
        assert_eq!(
            session.verify(&frame),
            Err(VerificationError::Authentication)
        );
    }
    #[test]
    fn replay_under_new_challenge_fails() {
        let mut original = session();
        let frame = receipt(&mut original, ReceiptCommand::InputSelection);
        let replacement = VerificationSession::new_for_driver(
            "new-run".into(),
            [8; 32],
            [9; 32],
            hash("app"),
            hash("driver"),
        )
        .unwrap();
        assert_eq!(
            replacement.verify(&frame),
            Err(VerificationError::SessionMismatch)
        );
    }
    #[test]
    fn report_requires_complete_ordered_affirmative_native_flow() {
        let mut session = session();
        let mut receipts = Vec::new();
        for command in required_commands(&[]) {
            receipts.push(receipt(&mut session, command));
        }
        assert!(session.report(&inputs(), &receipts).is_ok());
        receipts.pop();
        assert_eq!(
            session.report(&inputs(), &receipts),
            Err(VerificationError::Incomplete)
        );
    }
}
