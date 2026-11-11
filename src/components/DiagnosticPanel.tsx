type DiagnosticValue = { label: string; value?: string | number };
type DiagnosticPanelProps = { values: DiagnosticValue[] };

export function DiagnosticPanel({ values }: DiagnosticPanelProps) {
  const copy = () => void navigator.clipboard?.writeText(values.map(({ label, value }) => `${label}: ${value ?? "Không có"}`).join("\n"));
  return <aside className="diagnostic-panel" aria-labelledby="diagnostic-heading"><div className="section-title"><div><h2 id="diagnostic-heading">Chi tiết kỹ thuật</h2><p>Không bao gồm audio mẫu hoặc văn bản nhận diện.</p></div><button className="quiet-button" onClick={copy} type="button">Sao chép mã kỹ thuật</button></div><dl className="technical-grid">{values.map(({ label, value }) => <div key={label}><dt>{label}</dt><dd className="technical-value">{value ?? "Không có"}</dd></div>)}</dl></aside>;
}
