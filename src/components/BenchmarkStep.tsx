export type BenchmarkPolicy = {
  prompt: string;
  sampleRateHz: number;
  channels: number;
  maximumSampleSeconds: number;
  minimumCorrectness: number;
  maximumWarmRtf: number;
  maximumWarmP95Ms: number;
  temporarySourceOnly: boolean;
};

export type BenchmarkRow = {
  backend: "CPU" | "CUDA" | "Vulkan";
  status: "Đang kiểm tra" | "Đạt" | "Không đạt" | "Không được cài";
  build?: string;
  rtf?: number;
  p95?: number;
  correctness?: number;
  memory?: string;
  driver?: string;
  reason?: string;
};

export type BenchmarkReadiness = { backend: "CPU" | "CUDA" | "Vulkan"; installed: boolean; reason?: string };

type BenchmarkStepProps = { policy?: BenchmarkPolicy; sampleAccepted: boolean; canAcceptSample: boolean; recording: boolean; rows?: BenchmarkRow[]; onStartSample: () => void; onAcceptSample: () => void; onRetry: () => void };

const missing = "Không có";

export function BenchmarkStep({ policy, sampleAccepted, canAcceptSample, recording, rows, onStartSample, onAcceptSample, onRetry }: BenchmarkStepProps) {
  if (!policy) return <section className="benchmark-step" aria-live="polite"><p>Đang chuẩn bị điều kiện benchmark…</p></section>;
  if (!sampleAccepted) return <section className="benchmark-step" aria-labelledby="sample-heading">
    <div className="section-title"><div><h2 id="sample-heading">Ghi mẫu benchmark</h2><p>Chọn tạm một nguồn để ghi mẫu audio cho benchmark. Lựa chọn này sẽ không trở thành nguồn livestream.</p></div><span className="status-badge status-pending">Cần mẫu có tín hiệu</span></div>
    <p className="benchmark-prompt"><strong>Đọc rõ câu sau:</strong> {policy.prompt}</p>
    <dl className="technical-grid"><div><dt>Định dạng</dt><dd>{policy.sampleRateHz.toLocaleString("vi-VN")} Hz, mono</dd></div><div><dt>Thời lượng tối đa</dt><dd>{policy.maximumSampleSeconds} giây</dd></div><div><dt>Ngưỡng đúng</dt><dd>≥ {Math.round(policy.minimumCorrectness * 100)}%</dd></div><div><dt>Mục tiêu p95</dt><dd>≤ {policy.maximumWarmP95Ms.toLocaleString("vi-VN")} ms</dd></div></dl>
    <div className="wizard-actions">{recording ? <button className="primary-button" disabled={!canAcceptSample} onClick={onAcceptSample} type="button">Dùng mẫu này để benchmark</button> : <button className="primary-button" disabled={!canAcceptSample} onClick={onStartSample} type="button">Bắt đầu ghi mẫu</button>}</div>
  </section>;

  const visibleRows: BenchmarkRow[] = rows ?? (["CPU", "CUDA", "Vulkan"] as const).map((backend) => ({ backend, status: "Đang kiểm tra" }));
  const selected = visibleRows.find((row) => row.status === "Đạt");
  const noBackend = visibleRows.every((row) => row.status === "Không đạt" || row.status === "Không được cài");
  return <section className="benchmark-step" aria-labelledby="benchmark-heading">
    <div className="section-title"><div><h2 id="benchmark-heading">Benchmark</h2><p>CPU luôn được đo làm mốc. CUDA và Vulkan chỉ đạt khi self-test fixture, độ đúng và độ trễ đều vượt ngưỡng.</p></div><span className="status-badge status-pending">{selected ? "Hoàn tất" : "Đang kiểm tra"}</span></div>
    <div className="benchmark-matrix" role="table" aria-label="Ma trận benchmark backend">
      {visibleRows.map((row) => <div className="benchmark-row" key={row.backend} role="row"><strong role="cell">{row.backend}</strong><span role="cell" className={`status-badge ${row.status === "Đạt" ? "status-active" : row.status === "Không đạt" ? "status-unavailable" : "status-pending"}`}>{row.status}</span><span role="cell">Worker: {row.build ?? missing}</span><span role="cell">RTF: {row.rtf ?? missing}</span><span role="cell">p95: {row.p95 !== undefined ? `${row.p95} ms` : missing}</span><span role="cell">Độ đúng: {row.correctness !== undefined ? `${Math.round(row.correctness * 100)}%` : missing}</span><span role="cell">Bộ nhớ: {row.memory ?? missing}</span><span role="cell">Driver: {row.driver ?? missing}</span><span role="cell">{row.reason ?? missing}</span></div>)}
    </div>
    {selected && <div className="inline-alert"><div><strong>Cấu hình được chọn: {selected.backend}</strong><p>Mục tiêu p95 ba giây: {selected.p95 !== undefined && selected.p95 <= policy.maximumWarmP95Ms ? "Đạt" : "Không đạt"}.</p></div></div>}
    {noBackend && <div className="inline-alert destructive" role="alert"><div><strong>Không có backend nào vượt qua kiểm tra</strong><p>Xem chi tiết kỹ thuật, khắc phục lỗi rồi chạy lại benchmark.</p></div><button className="primary-button" onClick={onRetry} type="button">Thử lại benchmark</button></div>}
  </section>;
}
