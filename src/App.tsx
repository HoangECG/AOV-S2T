import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { SetupWizard } from "./components/SetupWizard";
import { ReadinessDashboard, type ReadinessSnapshot } from "./components/ReadinessDashboard";
import type { AudioLevel, Endpoint, EndpointCatalogues, Source } from "./components/DevicePicker";
import type { ModelInstallStatus } from "./components/ModelPreparationStep";
import type { BenchmarkPolicy, BenchmarkRow } from "./components/BenchmarkStep";
import { acceptAndRunBenchmark, cancelSetup, completeSetup, confirmRebenchmark, initializeSetup, retryBenchmark, runOfficialSourceTest, type BenchmarkReport, type SetupSnapshot } from "./setupFlow";

const emptyMeter: AudioLevel = { peakPercent: 0, rmsPercent: 0, state: "unavailable" };

function messageFrom(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = String(error.code);
    if (code === "conflict") return "Dừng kiểm tra nguồn hiện tại trước khi chọn nguồn khác.";
    if (code === "noSource") return "Chọn một nguồn âm thanh trước khi kiểm tra.";
    if (code === "unavailable") return "Nguồn đã chọn không còn khả dụng. Capture đã dừng để tránh dùng nhầm thiết bị.";
  }
  return String(error);
}

function benchmarkRowsFrom(report: BenchmarkReport): BenchmarkRow[] {
  return report.rows.map((row) => ({
    backend: row.worker === "cpu" ? "CPU" : row.worker === "cuda" ? "CUDA" : "Vulkan",
    status: row.outcome === "passed" ? "Đạt" : row.outcome === "notInstalled" ? "Không được cài" : "Không đạt",
    build: row.workerBuild, rtf: row.rtf, p95: row.p95Ms, correctness: row.correctness,
    memory: row.memoryBytes?.toLocaleString("vi-VN"), driver: row.driver, reason: row.reason,
  }));
}

export default function App() {
  const [catalogues, setCatalogues] = useState<EndpointCatalogues>({ inputs: [], desktopLoopback: [] });
  const [selected, setSelected] = useState<Source>();
  const [meter, setMeter] = useState<AudioLevel>(emptyMeter);
  const [captureOpen, setCaptureOpen] = useState(false);
  const [sampleRecording, setSampleRecording] = useState(false);
  const [message, setMessage] = useState("Đang tải danh sách thiết bị audio…");
  const [model, setModel] = useState<ModelInstallStatus>();
  const [benchmarkPolicy, setBenchmarkPolicy] = useState<BenchmarkPolicy>();
  const [benchmarkRows, setBenchmarkRows] = useState<BenchmarkRow[]>();
  const [snapshot, setSnapshot] = useState<SetupSnapshot>();
  const [showWizard, setShowWizard] = useState(true);
  const [sessionActive, setSessionActive] = useState(false);
  const [transcript, setTranscript] = useState("");
  const captureOpenRef = useRef(false);
  const resetCapture = useCallback(() => { captureOpenRef.current = false; setCaptureOpen(false); setMeter(emptyMeter); }, []);

  const applySnapshot = useCallback((next: SetupSnapshot) => {
    setSnapshot(next);
    setShowWizard(Boolean(next.currentStep));
  }, []);

  const refresh = useCallback(async () => {
    void invoke<ModelInstallStatus>("model_status")
      .then(setModel)
      .catch((error) => setMessage(messageFrom(error)));
    void invoke<BenchmarkPolicy>("benchmark_policy")
      .then(setBenchmarkPolicy)
      .catch((error) => setMessage(messageFrom(error)));
    void initializeSetup(invoke)
      .then(applySnapshot)
      .catch((error) => setMessage(messageFrom(error)));
    void invoke<EndpointCatalogues>("enumerate_audio_endpoints")
      .then(setCatalogues)
      .catch((error) => setMessage(messageFrom(error)));
  }, [applySnapshot]);

  useEffect(() => {
    void refresh();
    let unlisten: (() => void) | undefined;
    void listen<AudioLevel>("audio-level", (event) => {
      setMeter(event.payload);
      if (event.payload.state === "unavailable" && captureOpenRef.current) {
        resetCapture();
        setSessionActive(false);
        setMessage("Không thể mở nguồn audio đã chọn. Làm mới danh sách rồi chọn lại thiết bị.");
        void refresh();
      }
    }).then((stop) => { unlisten = stop; });
    let stopCaptureError: (() => void) | undefined;
    void listen<string>("audio-capture-error", (event) => {
      if (captureOpenRef.current) {
        setSessionActive(false);
        setMessage(`Không thể mở System Audio: ${event.payload}`);
      }
    }).then((stop) => { stopCaptureError = stop; });
    let stopSubtitleText: (() => void) | undefined;
    void listen<string>("subtitle-text", (event) => setTranscript(event.payload)).then((stop) => { stopSubtitleText = stop; });
    let stopSubtitleError: (() => void) | undefined;
    void listen<string>("subtitle-error", (event) => {
      captureOpenRef.current = false;
      setSessionActive(false);
      setMessage(event.payload);
    }).then((stop) => { stopSubtitleError = stop; });
    return () => { unlisten?.(); stopCaptureError?.(); stopSubtitleText?.(); stopSubtitleError?.(); };
  }, [refresh, resetCapture]);

  async function acknowledgeModel() {
    try { await invoke("acknowledge_verified_model"); applySnapshot(await initializeSetup(invoke)); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function choose(endpoint: Endpoint) {
    const source: Source = { kind: endpoint.kind, endpointId: endpoint.endpointId, displayName: endpoint.displayName };
    try { setSelected(await invoke<Source>("select_audio_source", { source })); setMeter(emptyMeter); setMessage(""); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function toggleCapture() {
    try {
      if (captureOpen) { await invoke("stop_audio_capture"); captureOpenRef.current = false; setCaptureOpen(false); }
      else { await invoke("start_audio_capture"); captureOpenRef.current = true; setCaptureOpen(true); }
      setMessage("");
    } catch (error) { resetCapture(); setMessage(messageFrom(error)); }
  }

  async function startSample() {
    try {
      if (captureOpen) await invoke("stop_audio_capture");
      await invoke("start_benchmark_recording");
      captureOpenRef.current = true; setCaptureOpen(true); setSampleRecording(true); setMessage("");
    } catch (error) { resetCapture(); setMessage(messageFrom(error)); }
  }

  async function acceptSample() {
    try {
      const result = await acceptAndRunBenchmark(invoke, () => { resetCapture(); setSampleRecording(false); });
      setBenchmarkRows(benchmarkRowsFrom(result.report)); setSelected(undefined); applySnapshot(result.snapshot); setMessage("");
    } catch (error) { setMessage(messageFrom(error)); }
  }

  async function retrySample() {
    try { await retryBenchmark(invoke, resetCapture); setCaptureOpen(true); setSampleRecording(true); setMessage(""); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function testOfficialSource() {
    if (!selected) return;
    try { applySnapshot(await runOfficialSourceTest(invoke, selected, resetCapture)); setMessage(""); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function finishSetup() {
    if (!snapshot) return;
    try { applySnapshot(await completeSetup(invoke, snapshot)); setMessage(""); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function cancel() {
    try { applySnapshot(await cancelSetup(invoke, () => { resetCapture(); setSampleRecording(false); setSelected(undefined); })); setMessage(""); }
    catch (error) { resetCapture(); setSampleRecording(false); setMessage(messageFrom(error)); }
  }

  async function continueSetup() {
    try {
      await invoke("begin_setup_reconfiguration", { step: snapshot?.state === "confirmationRequired" ? "benchmark" : "model" });
      applySnapshot(await initializeSetup(invoke));
    } catch (error) { setMessage(messageFrom(error)); }
  }

  async function rebenchmark() {
    try { applySnapshot(await confirmRebenchmark(invoke)); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function startSubtitles() {
    try { await invoke("start_subtitle_capture"); captureOpenRef.current = true; setTranscript(""); setSessionActive(true); setMessage(""); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function stopSubtitles() {
    try { await invoke("stop_subtitle_capture"); captureOpenRef.current = false; setSessionActive(false); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  async function openSubtitleWeb() {
    try { await invoke("open_subtitle_web"); }
    catch (error) { setMessage(messageFrom(error)); }
  }

  if (!showWizard) return <ReadinessDashboard message={message} onContinueSetup={() => void continueSetup()} onOpenSubtitleWeb={() => void openSubtitleWeb()} onRebenchmark={() => void rebenchmark()} onStartSubtitles={() => void startSubtitles()} onStopSubtitles={() => void stopSubtitles()} sessionActive={sessionActive} snapshot={snapshot as ReadinessSnapshot | undefined} transcript={transcript} />;
  return <SetupWizard benchmarkPolicy={benchmarkPolicy} benchmarkRows={benchmarkRows} canComplete={snapshot?.canComplete === true} captureOpen={captureOpen} catalogues={catalogues} currentStep={snapshot?.currentStep} message={message} meter={meter} model={model} onAcknowledgeModel={() => void acknowledgeModel()} onAcceptSample={() => void acceptSample()} onCancel={() => void cancel()} onChoose={choose} onComplete={() => void finishSetup()} onOpenSubtitleWeb={() => void openSubtitleWeb()} onRefresh={() => void refresh()} onRetryBenchmark={() => void retrySample()} onStartSample={() => void startSample()} onStartSubtitles={() => void startSubtitles()} onStopSubtitles={() => void stopSubtitles()} onTestOfficialSource={() => void testOfficialSource()} onToggleCapture={() => void toggleCapture()} sampleRecording={sampleRecording} selected={selected} sessionActive={sessionActive} transcript={transcript} />;
}
