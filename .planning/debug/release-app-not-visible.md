---
status: awaiting_human_verify
trigger: "Release app starts but no window is visible."
created: "2026-08-19"
updated: "2026-08-20T02:25:00+00:00"
---

# Debug Session: Release app not visible

## Symptoms

- Expected: the Windows desktop app opens a visible window.
- Actual: no window is visible and no error is shown.
- Reproduction: start `src-tauri\\target\\release\\live-subtitle-tool.exe`.

## Current Focus

- bug_class: bohrbug (the direct Cargo command deterministically compiles the Tauri dependency in development mode; the Tauri CLI command deterministically compiles it in production mode).
- hypothesis: The direct `cargo build --release` command omits Tauri’s `custom-protocol` feature. In Tauri 2.11.5 that emits `cargo:dev=true`, causing context generation to load `build.devUrl`; the Tauri CLI build enables the feature, emits `cargo:dev=false`, and embeds `build.frontendDist`. Tauri CLI always passes `--bins`, so its final output report names an auxiliary binary even though the intended application is compiled in the same production build.
- test: Have the user launch the final `src-tauri\\target\\release\\live-subtitle-tool.exe` while Vite is stopped.
- expecting: Its WebView loads the embedded frontend instead of the Edge “can't reach this page” error; no `localhost:1420` server is required.
- next_action: Await user confirmation of the release executable’s real Windows UI behavior; do not commit or archive before that confirmation.

reasoning_checkpoint:
  hypothesis: "The release executable navigates to localhost because direct Cargo omitted Tauri's custom-protocol feature, which makes Tauri generate a development context that selects build.devUrl."
  confirming_evidence:
    - "The direct Cargo release target's Tauri build-script output contains cargo:dev=true."
    - "The Tauri CLI release build regenerated dist and its Tauri build-script output contains cargo:dev=false."
    - "Tauri 2.6.3 context generation uses devUrl only when dev is true and otherwise embeds frontendDist."
  falsification_test: "A direct Cargo release build with no custom-protocol feature emits cargo:dev=false, or a Tauri CLI release build emits cargo:dev=true."
  fix_rationale: "An explicit script routes release builds through the tested Tauri CLI workflow, which supplies the feature that selects embedded frontendDist and runs beforeBuildCommand."
  blind_spots: "The automated environment cannot observe the final WebView page after launch; human verification must confirm the executable opens without Vite running."
  candidate_causes:
    - "code: the direct Cargo invocation omits Tauri's custom-protocol feature."
    - "config: the intentional devUrl setting becomes active when the omitted feature incorrectly leaves Tauri in dev mode."
  and_gate: "yes — the failed localhost navigation requires both the incorrect featureless release invocation and a configured devUrl; the latter is valid development configuration, so the fix targets the invocation."

## Evidence

- timestamp: "2026-08-19T16:42:59+00:00"
  checked: Debug knowledge-base recall
  found: MemPalace CLI is unavailable and `.planning/debug/knowledge-base.md` does not exist.
  implication: No prior-resolution candidate exists; investigate from current runtime and source evidence.
- timestamp: "2026-08-19T16:42:59+00:00"
  checked: Project state and configured debugger skills
  found: The only uncommitted project files are `.claude/settings.local.json`, `.planning/debug/`, and `model/`; no `agent_skills` are configured for `gsd-debugger`.
  implication: Preserve all pre-existing untracked files and do not assume an existing code change caused the symptom.
- timestamp: "2026-08-19T16:43:39+00:00"
  checked: Live Windows process and desktop session
  found: `live-subtitle-tool.exe` PID 3976 runs from the requested release path in active session 1, is responding, and has a nonzero main-window handle (3081242) titled `Live Subtitle Tool`.
  implication: The process did create a native window in the interactive desktop session; investigate its visibility/placement rather than process startup.
- timestamp: "2026-08-19T16:44:42+00:00"
  checked: Tauri configuration, complete Rust startup path, and live Win32 placement
  found: The app config creates a normal 960x700 window and `main.rs` contains no hide, position, or window-manipulation code. The live window is visible, non-minimized, non-maximized, normal (`show_cmd=1`), and occupies (26,26)-(1002,765), which intersects the 5760x1080 virtual desktop.
  implication: An application-controlled hidden or off-screen window is disproven; only a desktop-level cloaking/virtual-desktop condition remains to test.
- timestamp: "2026-08-19T16:45:35+00:00"
  checked: Live Win32/DWM visibility state
  found: DWM reports the window is not cloaked (`cloaked=0`), `WS_VISIBLE` is set, it has no owner window, and it is not the foreground window at observation time.
  implication: The release application has a normal, displayable native window; no source change is causally supported. The remaining observable explanation is ordinary desktop focus/occlusion, which requires user confirmation.
- timestamp: "2026-08-20T00:00:00+00:00"
  checked: Contradictory user runtime evidence and release build provenance
  found: The window was visible but its embedded Edge page showed “Hmmm… can't reach this page” while `http://localhost:1420` was unavailable. Starting Vite at that URL returned HTTP 200, after which the same executable was relaunched. The executable had been produced with `cargo build --manifest-path .\\src-tauri\\Cargo.toml --release --bin live-subtitle-tool`, although Tauri config defines `devUrl`, `beforeBuildCommand`, and `frontendDist`.
  implication: The original no-window symptom was a mischaracterization of a WebView navigation failure. The active competing cause is an incorrect release-build workflow, which must be compared against Tauri CLI behavior before changing code or scripts.
- timestamp: "2026-08-20T00:05:00+00:00"
  checked: Existing direct-Cargo release artifact and static frontend output
  found: `src-tauri/target/release/live-subtitle-tool.exe` exists and predates the current investigation; `dist/index.html` and its hashed assets exist. ASCII string inspection of that release executable found no `localhost:1420` or frontend path text.
  implication: The direct-Cargo hypothesis is not yet supported by the artifact itself; inspect generated Tauri configuration and Unicode strings before treating the observed Edge error as a compiled `devUrl` navigation.
- timestamp: "2026-08-20T00:10:00+00:00"
  checked: Direct Cargo build-script output
  found: The direct release build ran this project’s `tauri_build::build()` and emitted an application resource bundle under `src-tauri/target/release/build/live-subtitle-tool-*/out/`; the bundle is opaque binary data and does not expose `http://localhost:1420` through ASCII inspection.
  implication: Direct Cargo did not skip the Tauri Rust build integration. The unresolved question is specifically whether `--release` selects static frontend embedding without the Tauri CLI.
- timestamp: "2026-08-20T00:15:00+00:00"
  checked: Installed Tauri 2.6.3 code-generation source matching the project’s locked build dependency
  found: `tauri_build::build()` passes `dev: crate::is_dev()` into context generation. Context generation uses `build.devUrl` only when `dev` is true; otherwise it reads and embeds `build.frontendDist`. `is_dev()` is based on `DEP_TAURI_DEV`, an environment value emitted by Tauri’s own build script.
  implication: The build mode is determined by Tauri’s release/debug compilation state, not by whether the initiating command was `cargo build` or `tauri build`. The direct release target’s emitted `cargo:dev` setting is the decisive remaining test.
- timestamp: "2026-08-20T00:20:00+00:00"
  checked: Direct Cargo release target’s installed Tauri 2.11.5 build-script output and source
  found: `src-tauri/target/release/build/tauri-bcceac8f4be09d1d/output` contains `cargo:dev=true`. Tauri 2.11.5 sets that value to `!has_feature("custom-protocol")`, and the code generator selects `build.devUrl` whenever `dev` is true; otherwise it embeds `frontendDist`.
  implication: The initial direct-Cargo build command is the confirmed cause of a release executable navigating to `http://localhost:1420`: it did not enable Tauri’s production-only `custom-protocol` feature. A Tauri CLI release build must now demonstrate the expected `cargo:dev=false` behavior.
- timestamp: "2026-08-20T00:25:00+00:00"
  checked: Tauri CLI build invocation from the WSL shell
  found: `npm run tauri build -- --no-bundle` reached the Tauri CLI but failed before building because that Linux process cannot locate a `cargo` executable (`cargo metadata ... No such file or directory`).
  implication: This is an investigation-environment limitation, not a source or workflow failure. The prior executable and original command were built by the Windows toolchain, so the production comparison must be run through its Windows shell.
- timestamp: "2026-08-20T00:30:00+00:00"
  checked: Windows build-toolchain availability
  found: `cmd.exe` resolves Cargo 1.97.1, npm 11.16.0, and the project-local Tauri CLI 2.11.4.
  implication: The controlled release build can be run in the same Windows toolchain class as the original direct Cargo command.
- timestamp: "2026-08-20T00:35:00+00:00"
  checked: Windows Tauri CLI build start
  found: The CLI ran `beforeBuildCommand` successfully (`tsc -b && vite build`) and started compiling Tauri and `live-subtitle-tool`. No process was terminated.
  implication: Unlike direct Cargo, the documented release workflow demonstrably rebuilds the frontend before compiling the application. Final artifact mode still needs inspection after compilation completes.
- timestamp: "2026-08-20T00:45:00+00:00"
  checked: Completed Windows Tauri CLI release build
  found: The regenerated `src-tauri/target/release/live-subtitle-tool.exe` has a new timestamp and the corresponding new Tauri build-script output contains `cargo:dev=false`; the earlier direct-Cargo build output remains as `cargo:dev=true` for comparison.
  implication: The controlled comparison confirms the mechanism: Tauri CLI’s release workflow selects the static frontend whereas the direct Cargo release command selected the development server.
- timestamp: "2026-08-20T00:55:00+00:00"
  checked: New `npm run build:desktop` script invocation in the Windows toolchain
  found: The script invoked `tauri build --no-bundle`, ran `beforeBuildCommand`, rebuilt the Vite frontend successfully, and started compiling `live-subtitle-tool`.
  implication: The workflow guard is executable from the project itself; final artifact and production-mode checks remain after compilation finishes.
- timestamp: "2026-08-20T01:00:00+00:00"
  checked: Build process state and generated artifact after the first `build:desktop` invocation
  found: No Cargo or Rust compiler process remains; `src-tauri/target/release/live-subtitle-tool.exe` has a new timestamp and the active Tauri release build output remains `cargo:dev=false`.
  implication: The first script invocation completed a production-mode release build. A cached re-run will capture a direct zero exit status for the acceptance record.
- timestamp: "2026-08-20T01:05:00+00:00"
  checked: Cached `npm run build:desktop` run
  found: The script invoked `tauri build --no-bundle`, ran the complete frontend production build successfully, and entered the Rust application compilation phase.
  implication: The target acceptance test is running under the documented script; its final exit status and artifact mode will be captured from the active process.
- timestamp: "2026-08-20T01:10:00+00:00"
  checked: Completed cached `npm run build:desktop` run
  found: The command exited 0 and built the frontend, but its final report was `Built application at: ...phase1-evidence-driver.exe`, not `live-subtitle-tool.exe`.
  implication: The first workflow-script fix is incomplete because this Cargo package defines multiple binaries. Select the actual desktop binary explicitly before accepting the fix.
- timestamp: "2026-08-20T01:15:00+00:00"
  checked: Tauri CLI 2.11.4 build help
  found: `tauri build` accepts positional arguments for its runner and requires `--` to mark their start; Cargo’s `--bin live-subtitle-tool` can therefore be passed as `tauri build --no-bundle -- --bin live-subtitle-tool`.
  implication: The minimal workflow correction is to pass the intended Cargo binary through the Tauri CLI while preserving the CLI’s frontend build and `custom-protocol` feature behavior.
- timestamp: "2026-08-20T01:25:00+00:00"
  checked: Corrected `npm run build:desktop` invocation
  found: The script now invokes `tauri build --no-bundle -- --bin live-subtitle-tool`, runs the frontend production build successfully, and starts compiling the intended binary.
  implication: The target acceptance command is now both production-mode and binary-specific; capture its completed runner report before accepting it.
- timestamp: "2026-08-20T01:30:00+00:00"
  checked: Completed corrected `build:desktop` run
  found: The script exited 0 after compiling `live-subtitle-tool`, but Tauri CLI still reported `Built application at: ...phase1-evidence-driver.exe` despite receiving `-- --bin live-subtitle-tool`.
  implication: The development-server root cause remains confirmed, but the proposed package script cannot yet be accepted as a reliable release command for the requested executable. Trace the CLI-to-Cargo runner behavior rather than accepting an ambiguous artifact.
- timestamp: "2026-08-20T01:35:00+00:00"
  checked: Verbose Tauri CLI release build command construction
  found: Tauri invoked `cargo build --bin live-subtitle-tool --bins --features tauri/custom-protocol --release`. The runner argument reaches Cargo and Tauri unconditionally also requests all package binaries.
  implication: The intended binary is explicitly compiled with the production-only feature. The `phase1-evidence-driver.exe` report is a CLI artifact-selection quirk caused by the package’s extra binary, not evidence that the intended release executable remains in development mode.
- timestamp: "2026-08-20T01:40:00+00:00"
  checked: Completed verbose Tauri CLI release build
  found: The command exited 0 after Cargo finished the optimized release profile. It reported the auxiliary binary path, consistent with its unconditional `--bins` behavior.
  implication: The release compilation itself passed and explicitly included the intended binary with `tauri/custom-protocol`; static artifact and regression checks can now decide acceptance.
- timestamp: "2026-08-20T01:45:00+00:00"
  checked: Automated release-artifact and regression checks
  found: `live-subtitle-tool.exe` was regenerated at 05:09:45 and the active Tauri build output is `cargo:dev=false`. The binary still contains the configured dev URL as data, which is consistent with retaining full config; Tauri’s generated-context mode flag controls whether that URL is used. `npm test` passed 6/6 tests. No project Stryker configuration or package is installed.
  implication: The target script builds the intended executable in production mode and has no detected regression. Mutation testing is unavailable; perform the required revert-and-reconfirm guardrail next.
- timestamp: "2026-08-20T01:50:00+00:00"
  checked: Reverted package script
  found: With only the added `build:desktop` script line removed, `npm run build:desktop` fails immediately with `Missing script: "build:desktop"`.
  implication: The workflow guard is absent after reversion. Reproduce the original direct Cargo command now, then reapply the script and verify its production-mode outcome.
- timestamp: "2026-08-20T01:55:00+00:00"
  checked: Original direct Cargo release-command reproduction
  found: `cargo build --manifest-path .\\src-tauri\\Cargo.toml --release --bin live-subtitle-tool` started compiling the target through the Windows toolchain.
  implication: The exact reported workflow is being reproduced after removal of the guard; record its build mode before reapplying the package script.
- timestamp: "2026-08-20T02:00:00+00:00"
  checked: Completed original direct Cargo release-command reproduction
  found: The exact direct Cargo command exited 0 after completing the optimized release profile.
  implication: Inspect the generated Tauri build-script state now; this is the causal reversion half of the acceptance guardrail.
- timestamp: "2026-08-20T02:05:00+00:00"
  checked: Direct Cargo rebuilt release artifact and Tauri feature state
  found: The direct-Cargo-built `live-subtitle-tool.exe` was regenerated at 05:12:24 with size 13,268,992 bytes. The available Tauri dependency output for the same feature set is `cargo:dev=true`; the prior Tauri CLI production build was 13,363,200 bytes with `cargo:dev=false`.
  implication: The original direct command reintroduces the development-mode release executable. This completes the “bug returned on revert” half of the counterfactual; restore the scripted Tauri workflow to verify it removes that condition again.
- timestamp: "2026-08-20T02:15:00+00:00"
  checked: Restored `build:desktop` command start
  found: The restored script invoked the Tauri CLI with `-- --bin live-subtitle-tool`, rebuilt the Vite frontend successfully, and began the intended release compilation.
  implication: The final counterfactual reapplication is in progress; record the completed production artifact before accepting the fix.
- timestamp: "2026-08-20T02:20:00+00:00"
  checked: Completed restored `build:desktop` run
  found: The script exited 0 after rebuilding the frontend and release application. Tauri again reported the auxiliary binary due to `--bins`, while the verbose evidence establishes that `live-subtitle-tool` is compiled in the same command with `tauri/custom-protocol`.
  implication: The final production rebuild completed; inspect the intended executable itself, not the CLI’s auxiliary-binary status line, to finish the automated guardrail.
- timestamp: "2026-08-20T02:25:00+00:00"
  checked: Final restored artifact and source diff
  found: `live-subtitle-tool.exe` was regenerated at 05:13:54 with the production-build size of 13,363,200 bytes (versus 13,268,992 bytes after the direct Cargo reproduction). The active Tauri build state is `cargo:dev=false`. `git diff --check` passed and the only fix diff is the additive `build:desktop` package script; unrelated changes in `src-tauri/Cargo.toml`, `.claude/settings.local.json`, `.planning/debug/`, and `model/` remain untouched.
  implication: All automated guardrail signals applicable to this workflow fix pass. Human verification is required only to observe the final WebView behavior with Vite stopped.

## Eliminated

- hypothesis: The Tauri process starts in a non-interactive Windows session.
  evidence: PID 3976 is in the active console session (session 1), has a responding main window, and its main-window handle is nonzero.
  timestamp: "2026-08-19T16:43:39+00:00"
- hypothesis: Startup code hides the Tauri window or places it outside the display topology.
  evidence: Tauri config has no hidden/positioned window setting; complete `main.rs` has no window manipulation; Win32 reports visible, normal, non-minimized bounds fully inside the virtual desktop.
  timestamp: "2026-08-19T16:44:42+00:00"
- hypothesis: The window is cloaked or assigned to a different virtual desktop.
  evidence: `DwmGetWindowAttribute(DWMWA_CLOAKED)` returned success with `cloaked=0`, and `WS_VISIBLE` is set.
  timestamp: "2026-08-19T16:45:35+00:00"

## Resolution

root_cause: Direct `cargo build --release --bin live-subtitle-tool` omitted Tauri's `custom-protocol` feature. Tauri therefore emitted `cargo:dev=true` and compiled `build.devUrl` (`http://localhost:1420`) into the app context rather than embedding `frontendDist`.
fix: Added `build:desktop`, which calls `tauri build --no-bundle -- --bin live-subtitle-tool` to use the verified Tauri release workflow and explicitly build the desktop binary.
verification:
  target_test:
    result: pass
    evidence: "build:desktop exited 0 before and after deliberate reversion; verbose Tauri output showed Cargo receives --bin live-subtitle-tool --features tauri/custom-protocol --release."
  mutation_check:
    result: skipped
    reason_if_skipped: "No project Stryker package or configuration exists."
    mutant_killed: null
  no_op_deletion:
    result: pass
    deletion_justified_by_rca: false
    evidence: "The fix is one additive package-script line; git diff --check passed."
  adjacent_tests:
    result: pass
    suites_run: ["npm test (6/6 passing)", "beforeBuildCommand: npm run build"]
  revert_and_reconfirm:
    result: pass
    bug_returned_on_revert: true
    fixed_on_reapply: true
    evidence: "The original direct Cargo command rebuilt the 13,268,992-byte dev-mode artifact; restored build:desktop rebuilt the 13,363,200-byte production-mode artifact."
  guardrail_verdict: accepted
files_changed: [package.json]
