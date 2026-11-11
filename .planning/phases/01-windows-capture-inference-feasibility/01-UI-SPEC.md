---
phase: 1
slug: windows-capture-inference-feasibility
status: draft
shadcn_initialized: false
preset: none
created: 2026-08-19
---

# Phase 1 — UI Design Contract

> Visual and interaction contract for Windows Capture & Inference Feasibility. This phase covers setup, audio-source validation, model/benchmark readiness, and technical diagnostics only. It must not introduce the live-caption display, translation controls, overlay, or streaming controls planned for later phases.

---

## Design System

| Property | Value |
|----------|-------|
| Tool | none — custom local CSS and app-owned React components |
| Preset | not applicable |
| Component library | none |
| Icon library | none; use explicit Vietnamese text labels for all essential actions |
| Font | `Segoe UI, system-ui, sans-serif` |

The app uses a dark, high-contrast desktop surface suited to an operator preparing a stream. Build primitive components only as they are needed in this phase: `AppShell`, `SetupWizard`, `StepIndicator`, `DeviceGroup`, `DeviceRow`, `LevelMeter`, `ProgressPanel`, `BenchmarkMatrix`, `StatusBadge`, `DiagnosticPanel`, `InlineAlert`, `ModalDialog`, and `PrimaryButton`/`SecondaryButton`/`QuietButton`.

---

## Spacing Scale

Declared values (must be multiples of 4):

| Token | Value | Usage |
|-------|-------|-------|
| xs | 4px | Icon-equivalent gaps and compact status spacing |
| sm | 8px | Label-to-control spacing, list-row internals |
| md | 16px | Default control and card padding |
| lg | 24px | Card gaps and wizard section padding |
| xl | 32px | Main-column gaps |
| 2xl | 48px | Major screen-section breaks |
| 3xl | 64px | App-shell page padding on wide desktops |

Exceptions: interactive controls have a minimum 40px height; modal and wizard footer actions maintain a minimum 8px gap. On a viewport narrower than 800px, app-shell padding becomes 24px and content stacks into one column.

---

## Typography

Use exactly these four sizes and two weights. Do not introduce a smaller diagnostic typeface; diagnostics remain readable at 14px.

| Role | Size | Weight | Line Height |
|------|------|--------|-------------|
| Body / diagnostic value | 14px | 400 | 1.5 |
| Label / button / status | 14px | 600 | 1.5 |
| Section heading | 20px | 600 | 1.2 |
| Screen heading | 28px | 600 | 1.2 |

---

## Color

| Role | Value | Usage |
|------|-------|-------|
| Dominant (60%) | `#111318` | Window background and page background |
| Secondary (30%) | `#1C2028` | Cards, wizard frame, diagnostics panel, inactive list rows |
| Accent (10%) | `#4F8CFF` | Primary buttons, selected device row border, current wizard step, keyboard focus ring |
| Success | `#4ADE80` | Ready state, completed checks, passing backend/profile only |
| Warning | `#FBBF24` | CPU fallback, re-benchmark required, silent-source warning |
| Destructive | `#F87171` | Blocking failure, unavailable source, failed download/checksum, destructive confirmation only |
| Primary text | `#F8FAFC` | Headings and normal text |
| Secondary text | `#A7B0C0` | Supporting copy and diagnostic labels |

Accent is reserved for: **Hoàn tất thiết lập** and other primary forward actions, selected source rows, the current wizard step, and visible keyboard focus. It is never used for error or readiness meaning. All text/background combinations must meet WCAG AA contrast; status is conveyed by text and a badge label in addition to color.

---

## Screen and Interaction Contract

### App entry and readiness states

- **No known-good configuration:** open the setup wizard at its first incomplete step. The session-start UI does not exist in Phase 1.
- **Known-good configuration:** open the main `Sẵn sàng` screen. The visual focal point is the `Sẵn sàng` status and selected-source card, including source kind and live level; this is the first thing an operator sees and verifies. Show the current model, active admitted backend, CPU/GPU memory, driver version, and profile timestamp in the persistently visible but visually secondary technical-diagnostics card, without hiding it behind a settings page.
- **Reconfiguration:** `Thay đổi cấu hình` opens the wizard at the first affected step. It reuses an installed, verified model and prior benchmark data unless the model or hardware/backend changed.
- **Re-benchmark request:** when model, driver, backend, or hardware changed, show a warning banner: `Phần cứng hoặc mô hình đã thay đổi. Chạy benchmark lại trước khi dùng cấu hình mới.` Provide `Chạy benchmark lại` and `Giữ cấu hình hiện tại`. Do not run it until the user confirms.
- **Source unavailable:** stop capture immediately and replace its ready badge with `Nguồn không khả dụng`. Show the persisted device name and a `Chọn nguồn khác` action; never select the Windows default automatically.

### First-run and reconfiguration wizard

The wizard is a single centered frame, maximum 920px wide, with four named steps and a persistent progress indicator: `1 Tải mô hình` → `2 Ghi mẫu benchmark` → `3 Benchmark` → `4 Chọn nguồn livestream`.

1. **Tải mô hình**
   - State the pinned model name, revision, required disk space, destination drive, download size, and checksum-verification state before download begins.
   - While downloading, show percentage, transferred/total size, current action (`Đang tải`, `Đang xác minh`, or `Đang cài đặt`) and a determinate progress bar. Do not imply readiness before checksum verification succeeds.
   - On insufficient space, network failure, incomplete file, or checksum failure, render a blocking alert with the exact failed check and a single `Thử lại` action. Do not offer a smaller model fallback.
   - When the already installed pinned model is valid, show `Mô hình đã sẵn sàng` with revision and checksum status; proceed without downloading.

2. **Ghi mẫu benchmark**
   - Explain in one sentence: `Chọn tạm một nguồn để ghi mẫu audio cho benchmark. Lựa chọn này sẽ không trở thành nguồn livestream.`
   - Render two visually distinct groups: `Microphone / Input` and `Desktop / System Audio`. Each row has a radio control, friendly device name, availability status, and a live captured-PCM level meter once selected. Only one row across both groups may be selected.
   - `Desktop / System Audio` describes the selected render device as `Loopback hệ thống`; do not display or request a Stereo Mix device.
   - The primary action remains disabled until the selected temporary source has a non-silent signal. Then show `Bắt đầu ghi mẫu`; after a successful recording, show `Dùng mẫu này để benchmark`.
   - A temporary source ID and recorded sample remain candidate setup data only. Do not persist either as the official source or expose an import-file workflow.

3. **Benchmark**
   - Start automatically after the user accepts the recorded sample. Display an indeterminate stage label while a worker is starting, then determinate per-candidate progress.
   - Show a matrix with CPU, CUDA (if packaged), and Vulkan (if packaged) rows. Each row exposes `Đang kiểm tra`, `Đạt`, `Không đạt`, or `Không được cài`; show backend name, result, real-time factor, p95 turnaround, and failure reason when available.
   - Keep the CPU row visible and benchmarked even if a GPU row passes. A GPU brand alone must never produce a pass badge.
   - On completion, state one selected profile plainly: `Cấu hình được chọn: {backend}` and show the three-second p95 target result. If no worker passes, stay in the wizard with the full failure checklist and `Thử lại benchmark`; session readiness remains blocked.

4. **Chọn nguồn livestream**
   - Repeat the two source groups and one-selection behavior. This is the only selection eligible to be saved as the official source.
   - After selection, show its captured-PCM level meter and a single `Chạy thử nhận diện tiếng Việt` action. A mere device label or endpoint peak is insufficient.
   - Show separate check rows: `Có tín hiệu audio` and `Nhận diện thử tiếng Việt hoàn tất`. Only when both pass is `Hoàn tất thiết lập` enabled.
   - On silence, lost device, or failed test caption, leave the wizard in place with the failed check, a short explanation, and `Thử lại`. Do not commit new source/model/profile data.

### Cancellation and commit boundary

- `Hủy thiết lập` is always available. If no candidate values changed, close immediately. Otherwise open a confirmation dialog before discarding candidate setup data.
- Write model/backend/source/profile configuration only after all required checks in the wizard pass. Cancellation or failure preserves the previous known-good configuration exactly.
- When the first-ever setup is cancelled, return to a blocked empty readiness screen, not a misleading ready screen. Its only primary action is `Tiếp tục thiết lập`.

### Device and meter behavior

- Device names are display text, not identity. Show an unavailable state against the exact saved endpoint; do not relabel a default Windows device as the saved source.
- Use a horizontal 0–100% captured-PCM meter with a numeric percentage and the adjacent state text `Có tín hiệu`, `Im lặng`, or `Không khả dụng`. Update at least four times per second while capture is open; respect reduced-motion by changing the fill without animation.
- A source is `Im lặng` only after the defined capture-silence threshold; it is not an active/ready substitute. The inline warning offers `Kiểm tra nguồn` and `Chọn nguồn khác` where applicable.

### Technical diagnostics

The main screen has a persistently visible `Chi tiết kỹ thuật` card, not an optional hidden advanced mode. Display values in a two-column label/value grid: model name and pinned revision, install/checksum state, active backend, selected worker build, GPU name, VRAM or system RAM used/available, driver version, benchmark timestamp, real-time factor, p95 turnaround, selected source kind, friendly name, and source endpoint status. Missing values show `Không có` rather than an empty cell.

Use monospaced styling only for opaque endpoint ID, model revision, and driver/build identifiers; wrap within the panel and provide a `Sao chép mã kỹ thuật` action for those exact values. Never log or render benchmark raw audio or transcript content in diagnostics by default.

### Focus, keyboard, and layout

- Focus enters the wizard heading on step changes, then moves to the first actionable control. `Tab` follows visual order; `Space` selects a device radio row; `Enter` activates the focused primary action; `Esc` requests `Hủy thiết lập` only when a confirmation dialog is not already open.
- Radio rows have a 2px accent focus outline and a clear selected label; buttons and controls retain visible focus even with a mouse-friendly desktop layout.
- Desktop layouts at 1000px and above use a 2:1 main/diagnostic grid. From 800–999px, diagnostics move below the main card. Below 800px, all wizard and main content stacks; device lists remain scrollable.

---

## Copywriting Contract

| Element | Copy |
|---------|------|
| Primary CTA | `Hoàn tất thiết lập` |
| Empty state heading | `Chưa có cấu hình sẵn sàng` |
| Empty state body | `Hoàn tất tải mô hình, benchmark và kiểm tra nguồn audio trước khi dùng công cụ.` Primary action: `Tiếp tục thiết lập`. |
| No devices state | `Không tìm thấy thiết bị audio phù hợp. Kiểm tra thiết bị trong Windows rồi làm mới danh sách.` Action: `Làm mới danh sách`. |
| Source-unavailable error | `Nguồn đã chọn không còn khả dụng. Capture đã dừng để tránh dùng nhầm thiết bị.` Action: `Chọn nguồn khác`. |
| Silent-source error | `Chưa nhận được tín hiệu audio từ nguồn này. Phát thử audio hoặc chọn nguồn khác.` Action: `Kiểm tra nguồn`. |
| Model error | `Mô hình chưa sẵn sàng. Kiểm tra dung lượng, kết nối và tệp tải xuống rồi thử lại.` Action: `Thử lại`. |
| Benchmark failure | `Không có backend nào vượt qua kiểm tra. Xem chi tiết kỹ thuật, khắc phục lỗi rồi chạy lại benchmark.` Action: `Thử lại benchmark`. |
| Test-caption failure | `Chưa xác nhận được nhận diện tiếng Việt từ nguồn đã chọn. Kiểm tra tín hiệu rồi thử lại.` Action: `Chạy thử lại`. |
| Destructive confirmation | `Hủy thiết lập mới? Các thay đổi đang thực hiện sẽ bị bỏ. Cấu hình đã hoạt động trước đó sẽ không thay đổi.` Actions: `Tiếp tục thiết lập` and `Hủy thiết lập`. |

---

## UI Considerations

Applicable state considerations resolved: 8 covered, 0 backstop, 0 unresolved.

| Category | Element(s) | Status | Resolution / Reason |
|----------|------------|--------|---------------------|
| empty | Device groups; first-use readiness | ✅ covered | Empty device groups render the documented no-devices copy and refresh action; no prior configuration renders the documented blocked readiness state. |
| loading | Device enumeration, model download, checksum, worker startup, benchmark, Vietnamese test caption | ✅ covered | Each in-flight operation renders a named current stage; downloads and per-candidate benchmarks use determinate progress when totals are known. |
| error | Model checks, temporary/official source, backend candidates, test caption | ✅ covered | Failures name the failed check, keep the wizard at the failed step, preserve last-known-good configuration, and expose exactly the recovery action documented in Copywriting. |
| populated | Device rows, benchmark matrix, diagnostics card | ✅ covered | Available devices show group, name, radio selection, availability, and meter; completed benchmark rows and full technical values remain visible. |
| partial | Backend matrix and diagnostics | ✅ covered | Pending or unavailable workers display explicit `Đang kiểm tra` or `Không được cài`; absent diagnostic values render `Không có`, never a fabricated pass. |
| overflow | Device lists, diagnostic grid, long error details | ✅ covered | Device lists scroll after 8 rows per group; the diagnostics card scrolls vertically inside its panel; long identifiers wrap or are copied without horizontal page overflow. |
| zero-one-many | Microphone/Input and Desktop/System Audio groups | ✅ covered | Each group supports zero devices, one radio row, or many scrollable rows without changing the one-active-source rule. |
| long-text | Device labels, model revision, driver strings, failure reason, buttons | ✅ covered | Device labels and messages wrap to two lines before ellipsis; opaque identifiers wrap in the diagnostics grid and retain a copy action; controls never truncate the action verb. |

---

## Registry Safety

| Registry | Blocks Used | Safety Gate |
|----------|-------------|-------------|
| shadcn official | none | not applicable — user declined shadcn initialization |
| third-party registries | none | no third-party registry or block is permitted in this phase |

---

## Checker Sign-Off

- [ ] Dimension 1 Copywriting: PASS
- [ ] Dimension 2 Visuals: PASS
- [ ] Dimension 3 Color: PASS
- [ ] Dimension 4 Typography: PASS
- [ ] Dimension 5 Spacing: PASS
- [ ] Dimension 6 Registry Safety: PASS

**Approval:** approved 2026-08-19 — user confirmed all resolved UI state considerations
