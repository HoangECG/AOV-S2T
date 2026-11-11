pub mod benchmark;
pub mod download;
pub mod manifest;
pub mod runner;
pub mod transaction;

use serde::Serialize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum ModelInstallState {
    Absent,
    Ready,
    UpdateRequiresConfirmation {
        installed_revision: String,
        candidate_revision: String,
    },
    Failed {
        check: String,
        detail: String,
        retryable: bool,
    },
}

impl ModelInstallState {
    pub fn failed(error: download::InstallError) -> Self {
        let (check, detail, retryable) = error.ui_detail();
        Self::Failed {
            check,
            detail,
            retryable,
        }
    }
}
