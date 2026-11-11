use tauri::AppHandle;

use crate::inference::download::{self, ModelInstallStatus};

#[tauri::command]
pub fn model_status(app: AppHandle) -> Result<ModelInstallStatus, String> {
    download::status_info(&app).map_err(|error| error.ui_detail().1)
}
