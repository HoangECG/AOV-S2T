use live_subtitle_tool::{
    audio::{capture::CaptureController, source::SourceSelection},
    commands,
    commands::verification::VerificationTransport,
    setup::{config::SetupConfigStore, state::SetupController},
    subtitle_web::{self, CaptionStore},
};
use tauri::Manager;
fn main() {
    let selection = SourceSelection::default();
    let launch_selection = selection.clone();
    let capture = CaptureController::new(selection.clone());
    let captions = CaptionStore::new();
    let _web_server = subtitle_web::start(captions.clone());
    tauri::Builder::default()
        .manage(capture)
        .manage(captions)
        .manage(commands::subtitles::SubtitleService::default())
        .manage(selection)
        .manage(VerificationTransport::from_inherited_driver())
        .setup(move |app| {
            let path = app.path().app_local_data_dir()?.join("setup.json");
            let store = SetupConfigStore::new(path);
            let setup =
                SetupController::from_store(&store).unwrap_or_else(|_| SetupController::new(store));
            commands::setup::revalidate_loaded_setup(&app.handle(), &setup, &launch_selection);
            app.manage(setup);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::audio::enumerate_audio_endpoints,
            commands::audio::select_audio_source,
            commands::audio::start_audio_capture,
            commands::audio::stop_audio_capture,
            commands::model::model_status,
            commands::benchmark::benchmark_policy,
            commands::benchmark::start_benchmark_recording,
            commands::benchmark::finish_and_run_benchmark,
            commands::benchmark::cancel_benchmark_transaction,
            commands::benchmark::retry_benchmark_recording,
            commands::benchmark::benchmark_readiness,
            commands::setup::setup_readiness,
            commands::setup::begin_setup_reconfiguration,
            commands::setup::cancel_setup_reconfiguration,
            commands::setup::cancel_setup_transaction,
            commands::setup::acknowledge_verified_model,
            commands::setup::accept_native_benchmark_profile,
            commands::setup::set_current_official_source,
            commands::setup::start_official_source_test,
            commands::setup::finish_official_source_test,
            commands::setup::complete_setup,
            commands::setup::setup_snapshot,
            commands::verification::verification_transport_status,
            commands::subtitles::start_subtitle_capture,
            commands::subtitles::stop_subtitle_capture,
            commands::subtitles::open_subtitle_web
        ])
        .run(tauri::generate_context!())
        .expect("failed to run local application");
}
