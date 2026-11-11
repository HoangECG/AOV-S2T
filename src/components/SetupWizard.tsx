import { useEffect, useRef, useState } from "react";
import { BenchmarkStep, type BenchmarkPolicy, type BenchmarkRow } from "./BenchmarkStep";
import { DevicePicker, type AudioLevel, type Endpoint, type EndpointCatalogues, type Source } from "./DevicePicker";
import { DiagnosticPanel } from "./DiagnosticPanel";
import { LevelMeter } from "./LevelMeter";
import { ModelPreparationStep, type ModelInstallStatus } from "./ModelPreparationStep";

type Step = "model" | "benchmarkSample" | "benchmark" | "officialSource";
type SetupWizardProps = {
  catalogues: EndpointCatalogues; selected?: Source; meter: AudioLevel; captureOpen: boolean; message: string;
  sampleRecording: boolean;
  model?: ModelInstallStatus; benchmarkPolicy?: BenchmarkPolicy; benchmarkRows?: BenchmarkRow[];
  currentStep?: Step; canComplete: boolean; onChoose: (endpoint: Endpoint) => void; onRefresh: () => void;
  onToggleCapture: () => void; onAcknowledgeModel: () => void; onStartSample: () => void;
  onAcceptSample: () => void; onRetryBenchmark: () => void; onTestOfficialSource: () => void; onComplete: () => void; onCancel: () => void; onStartSubtitles: () => void; onStopSubtitles: () => void; onOpenSubtitleWeb: () => void; sessionActive: boolean; transcript: string;
};

const steps: { value: Step; label: string }[] = [
  { value: "model", label: "Chuẩn bị mô hình" }, { value: "benchmarkSample", label: "Ghi mẫu benchmark" },
  { value: "benchmark", label: "Benchmark" }, { value: "officialSource", label: "Chọn nguồn livestream" },
];

export function SetupWizard(props: SetupWizardProps) {
  const [confirmCancel, setConfirmCancel] = useState(false);
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => { heading.current?.focus(); }, [props.currentStep]);
  const step = props.currentStep ?? "model";
  const index = steps.findIndex(({ value }) => value === step);
  const modelReady = props.model?.state.state === "ready";
  const isSample = step === "benchmarkSample";
  const isOfficial = step === "officialSource";
  const canRecord = Boolean(props.selected) && (!props.sampleRecording || props.meter.state === "signal");

  return <main className="app-shell"><section className="wizard-frame" aria-labelledby="wizard-heading">
    <header><p className="eyebrow">Thiết lập cục bộ</p><h1 id="wizard-heading" ref={heading} tabIndex={-1}>{steps[index]?.label ?? "Thiết lập"}</h1>
      {(isSample || isOfficial) && <p>{isSample ? "Chọn tạm một nguồn để ghi mẫu audio cho benchmark. Lựa chọn này sẽ không trở thành nguồn livestream." : "Chọn nguồn livestream chính thức rồi chạy thử nhận diện tiếng Việt."}</p>}</header>
    <ol className="step-indicator" aria-label="Tiến trình thiết lập">{steps.map(({ value, label }, position) => <li className={position === index ? "is-current" : position < index ? "is-complete" : ""} key={value}><span>{position + 1}</span>{label}</li>)}</ol>
    {step === "model" && <><ModelPreparationStep onRefresh={props.onRefresh} status={props.model} />
      {modelReady && <><DevicePicker catalogues={props.catalogues} disabled={props.sessionActive} onChoose={props.onChoose} onRefresh={props.onRefresh} selected={props.selected} />
        <LevelMeter level={props.meter} selected={Boolean(props.selected)} />
        <section className="subtitle-output" aria-live="polite"><strong>{props.sessionActive ? "Đang nhận dạng…" : "Có thể chạy ngay — benchmark là tùy chọn."}</strong><p>{props.transcript || "Chọn nguồn audio để bắt đầu phụ đề."}</p><button className="quiet-button" onClick={props.onOpenSubtitleWeb} type="button">Mở trang phụ đề trên web</button></section>
        <footer className="wizard-actions"><button className="primary-button" disabled={!props.selected} onClick={props.sessionActive ? props.onStopSubtitles : props.onStartSubtitles} type="button">{props.sessionActive ? "Dừng phụ đề" : "Bắt đầu phụ đề"}</button><button className="quiet-button" disabled={props.sessionActive} onClick={props.onAcknowledgeModel} type="button">Thiết lập benchmark sau</button></footer></>}</>}
    {isSample && <><DevicePicker catalogues={props.catalogues} disabled={props.captureOpen} onChoose={props.onChoose} onRefresh={props.onRefresh} selected={props.selected} />
      <LevelMeter level={props.meter} selected={Boolean(props.selected)} />
      <footer className="wizard-actions"><button className="secondary-button" disabled={!props.selected} onClick={props.onToggleCapture} type="button">{props.captureOpen ? "Dừng kiểm tra" : "Kiểm tra nguồn"}</button></footer>
      <BenchmarkStep canAcceptSample={canRecord} onAcceptSample={props.onAcceptSample} onRetry={props.onRetryBenchmark} onStartSample={props.onStartSample} policy={props.benchmarkPolicy} recording={props.sampleRecording} sampleAccepted={false} /></>}
    {step === "benchmark" && <div className="setup-grid"><BenchmarkStep canAcceptSample={false} onAcceptSample={props.onAcceptSample} onRetry={props.onRetryBenchmark} onStartSample={props.onStartSample} policy={props.benchmarkPolicy} recording={false} rows={props.benchmarkRows} sampleAccepted />
      <DiagnosticPanel values={diagnostics(props.benchmarkRows)} /></div>}
    {isOfficial && <><DevicePicker catalogues={props.catalogues} disabled={props.captureOpen} onChoose={props.onChoose} onRefresh={props.onRefresh} selected={props.selected} />
      <LevelMeter level={props.meter} selected={Boolean(props.selected)} />
      <section className="official-checks" aria-live="polite"><p><strong>Có tín hiệu audio:</strong> {props.canComplete ? "Đạt" : "Chờ kiểm tra native"}</p><p><strong>Nhận diện thử tiếng Việt hoàn tất:</strong> {props.canComplete ? "Đạt" : "Chưa hoàn tất"}</p></section>
      <footer className="wizard-actions"><button className="secondary-button" disabled={!props.selected} onClick={props.onToggleCapture} type="button">{props.captureOpen ? "Dừng kiểm tra" : "Kiểm tra nguồn"}</button><button className="primary-button" disabled={!props.selected || props.captureOpen} onClick={props.onTestOfficialSource} type="button">Chạy thử nhận diện tiếng Việt</button></footer></>}
    {props.message && <p className="message" role="alert">{props.message}</p>}
    <footer className="wizard-actions"><button className="quiet-button" onClick={() => setConfirmCancel(true)} type="button">Hủy thiết lập</button>{isOfficial && <button className="primary-button" disabled={!props.canComplete} onClick={props.onComplete} type="button">Hoàn tất thiết lập</button>}</footer>
    {confirmCancel && <div className="modal-backdrop" role="presentation"><section aria-describedby="cancel-copy" aria-labelledby="cancel-heading" aria-modal="true" className="modal-dialog" role="dialog"><h2 id="cancel-heading">Hủy thiết lập mới?</h2><p id="cancel-copy">Các thay đổi đang thực hiện sẽ bị bỏ. Cấu hình đã hoạt động trước đó sẽ không thay đổi.</p><div className="wizard-actions"><button autoFocus className="secondary-button" onClick={() => setConfirmCancel(false)} type="button">Tiếp tục thiết lập</button><button className="primary-button destructive-button" onClick={props.onCancel} type="button">Hủy thiết lập</button></div></section></div>}
  </section></main>;
}

function diagnostics(rows?: BenchmarkRow[]) {
  const selected = rows?.find(({ status }) => status === "Đạt");
  return [
    { label: "Backend đang chọn", value: selected?.backend }, { label: "Worker build", value: selected?.build },
    { label: "RAM / VRAM", value: selected?.memory }, { label: "Driver", value: selected?.driver },
    { label: "RTF", value: selected?.rtf }, { label: "p95", value: selected?.p95 },
  ];
}
