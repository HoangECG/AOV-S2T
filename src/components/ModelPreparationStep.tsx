export type ModelSource = {
  repository: string;
  revision: string;
  checkpoint: string;
};

export type ModelManifest = {
  modelId: string;
  revision: string;
  artifactName: string;
  expectedBytes: number;
  sha256: string;
  format: string;
  installationMode: string;
  source: ModelSource;
  workerCompatibility: string;
  license: string;
};

export type ModelInstallState =
  | { state: "absent" }
  | { state: "ready" }
  | { state: "updateRequiresConfirmation"; installedRevision: string; candidateRevision: string }
  | { state: "failed"; check: string; detail: string; retryable: boolean };

export type ModelInstallStatus = { manifest: ModelManifest; state: ModelInstallState; destination: string };

type ModelPreparationStepProps = { status?: ModelInstallStatus; onRefresh: () => void };

function bytes(value: number): string {
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB (${value.toLocaleString("vi-VN")} byte)`;
}

export function ModelPreparationStep({ status, onRefresh }: ModelPreparationStepProps) {
  if (!status) return <section className="model-download-step" aria-live="polite"><p>Đang đọc thông tin mô hình…</p></section>;
  const { manifest, state, destination } = status;
  const ready = state.state === "ready";
  const failed = state.state === "failed";
  const update = state.state === "updateRequiresConfirmation";

  return <section className="model-download-step" aria-labelledby="model-heading">
    <div className="section-title"><div><h2 id="model-heading">Chuẩn bị mô hình</h2><p>PhoWhisper-large được chuyển đổi và xác minh ngay trên máy; ứng dụng không tải hoặc upload mô hình.</p></div><span className={`status-badge ${ready ? "status-active" : failed || update ? "status-unavailable" : "status-pending"}`}>{ready ? "Mô hình đã sẵn sàng" : failed ? "Mô hình chưa sẵn sàng" : update ? "Cần xác nhận cập nhật" : "Cần chuẩn bị cục bộ"}</span></div>
    <dl className="model-details">
      <div><dt>Tên mô hình</dt><dd>{manifest.modelId}</dd></div>
      <div><dt>Checkpoint chính thức</dt><dd className="technical-value">{manifest.source.repository}@{manifest.source.revision}</dd></div>
      <div><dt>Tệp GGML cần có</dt><dd>{bytes(manifest.expectedBytes)}</dd></div>
      <div><dt>Đích cài đặt</dt><dd className="technical-value">{destination || "Không có"}</dd></div>
      <div><dt>Định dạng</dt><dd>{manifest.format}</dd></div>
      <div><dt>Xác minh</dt><dd>{ready ? "SHA-256 khớp manifest" : "Chưa xác minh"}</dd></div>
    </dl>
    {failed && <div className="inline-alert destructive" role="alert"><div><strong>Mô hình chưa sẵn sàng</strong><p>Kiểm tra thất bại: {state.check}. {state.detail}</p></div></div>}
    {update && <div className="inline-alert warning" role="alert"><div><strong>Cần xác nhận cập nhật</strong><p>Phiên bản {state.candidateRevision} chưa thay thế mô hình đã xác thực {state.installedRevision}. Xác nhận và benchmark lại ở bước cấu hình sau.</p></div></div>}
    {!ready && !update && <div className="inline-alert warning"><div><strong>Chuẩn bị GGML trước khi tiếp tục</strong><p>Từ thư mục dự án, chạy <code>powershell -ExecutionPolicy Bypass -File .\scripts\prepare-phowhisper-model.ps1</code>. Lệnh này không cần <code>hf auth login</code> hoặc <code>hf upload</code>.</p></div><button className="primary-button" onClick={onRefresh} type="button">Kiểm tra lại</button></div>}
  </section>;
}
