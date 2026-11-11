export type ReadinessSnapshot = {
  state: "ready" | "setupRequired" | "confirmationRequired" | "sourceUnavailable" | "blocked";
  source?: { kind: string; displayName: string; endpointId: string; endpointStatus: string };
  blockingChecks: string[];
  diagnostics: Record<string, string | number | null | undefined>;
};

type ReadinessDashboardProps = { snapshot?: ReadinessSnapshot; onContinueSetup: () => void; onRebenchmark: () => void; onStartSubtitles: () => void; onStopSubtitles: () => void; onOpenSubtitleWeb: () => void; sessionActive: boolean; transcript: string; message?: string };

const diagnosticLabels: Record<string, string> = {
  modelId: "Mô hình", modelRevision: "Phiên bản đã ghim", modelChecksumState: "Trạng thái checksum", backend: "Backend đang chọn", workerBuild: "Worker build",
  gpuName: "GPU", ramBytes: "RAM", vramBytes: "VRAM", driver: "Driver", benchmarkTimestamp: "Thời điểm benchmark", rtf: "RTF", p95Ms: "p95",
};

export function ReadinessDashboard({ snapshot, onContinueSetup, onRebenchmark, onStartSubtitles, onStopSubtitles, onOpenSubtitleWeb, sessionActive, transcript, message }: ReadinessDashboardProps) {
  const unavailable = snapshot?.state === "sourceUnavailable";
  const ready = snapshot?.state === "ready";
  const title = ready ? "Sẵn sàng" : unavailable ? "Nguồn không khả dụng" : "Chưa có cấu hình sẵn sàng";
  const body = unavailable
    ? "Nguồn đã chọn không còn khả dụng. Capture đã dừng để tránh dùng nhầm thiết bị."
    : "Hoàn tất tải mô hình, benchmark và kiểm tra nguồn audio trước khi dùng công cụ.";
  const values = Object.entries(snapshot?.diagnostics ?? {}).map(([key, value]) => ({ label: diagnosticLabels[key] ?? key, value: value ?? "Không có" }));
  const copy = () => void navigator.clipboard?.writeText(values.map(({ label, value }) => `${label}: ${value}`).join("\n"));

  return <main className="app-shell"><section className="readiness-layout" aria-labelledby="readiness-heading">
    <section className="readiness-card">
      <p className="eyebrow">Trạng thái cục bộ</p><h1 id="readiness-heading">{title}</h1><p>{body}</p>
      {snapshot?.source && <div className={`source-card ${unavailable ? "is-unavailable" : ""}`}><strong>{snapshot.source.displayName}</strong><span>{snapshot.source.kind} · {snapshot.source.endpointStatus}</span><code>{snapshot.source.endpointId}</code></div>}
      {snapshot?.state === "confirmationRequired" && <div className="inline-alert warning" role="alert"><div><strong>Phần cứng hoặc mô hình đã thay đổi. Chạy benchmark lại trước khi dùng cấu hình mới.</strong></div><button className="primary-button" onClick={onRebenchmark} type="button">Chạy benchmark lại</button><button className="quiet-button" onClick={onContinueSetup} type="button">Giữ cấu hình hiện tại</button></div>}
      {!ready && <><ul className="checklist" aria-label="Các điều kiện còn thiếu">{(snapshot?.blockingChecks.length ? snapshot.blockingChecks : ["Mở thiết lập để bắt đầu kiểm tra"]).map((check) => <li key={check}>{check}</li>)}</ul><button className="primary-button" onClick={onContinueSetup} type="button">{unavailable ? "Chọn nguồn khác" : "Tiếp tục thiết lập"}</button></>}
      {message && <p className="message" role="alert">{message}</p>}
      {ready && <section className="subtitle-session" aria-live="polite"><p className="ready-copy">Nguồn đã chọn và cấu hình đã được native xác minh.</p><div className="wizard-actions"><button className="primary-button" onClick={sessionActive ? onStopSubtitles : onStartSubtitles} type="button">{sessionActive ? "Dừng phụ đề" : "Bắt đầu phụ đề"}</button></div><div className="subtitle-output"><strong>{sessionActive ? "Đang nghe và nhận dạng…" : "Phụ đề sẽ hiện ở đây"}</strong><p>{transcript || "Chưa có lời thoại được nhận dạng."}</p><button className="quiet-button" onClick={onOpenSubtitleWeb} type="button">Mở trang phụ đề trên web</button></div></section>}
    </section>
    <aside className="diagnostic-panel" aria-labelledby="diagnostic-heading"><div className="section-title"><div><h2 id="diagnostic-heading">Chi tiết kỹ thuật</h2><p>Không bao gồm audio mẫu hoặc văn bản nhận diện.</p></div><button className="quiet-button" onClick={copy} type="button">Sao chép mã kỹ thuật</button></div><dl className="technical-grid">{values.length ? values.map(({ label, value }) => <div key={label}><dt>{label}</dt><dd className="technical-value">{value}</dd></div>) : <div><dt>Trạng thái</dt><dd>Không có</dd></div>}</dl></aside>
  </section></main>;
}
