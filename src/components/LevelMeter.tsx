import type { AudioLevel } from "./DevicePicker";

type LevelMeterProps = { level: AudioLevel; selected: boolean };
const stateCopy: Record<AudioLevel["state"], string> = { signal: "Có tín hiệu", silent: "Im lặng", unavailable: "Không khả dụng" };

export function LevelMeter({ level, selected }: LevelMeterProps) {
  const state = selected ? level.state : undefined;
  const percentage = Math.round(level.peakPercent);
  return <section className="level-meter" aria-labelledby="meter-heading" aria-live="polite">
    <div className="section-title"><div><h2 id="meter-heading">Mức PCM đã capture</h2><p>Đo từ PCM của nguồn đã chọn, không phải mức mặc định của Windows.</p></div>{state && <span className={`status-badge meter-${state}`}>{stateCopy[state]}</span>}</div>
    <div aria-label={`Mức PCM ${percentage}%`} aria-valuemax={100} aria-valuemin={0} aria-valuenow={percentage} className="meter-track" role="progressbar"><span className="meter-fill" style={{ width: `${Math.min(100, Math.max(0, level.peakPercent))}%` }} /></div>
    <div className="meter-values"><strong>{percentage}%</strong><span>RMS {Math.round(level.rmsPercent)}%</span></div>
    {state === "silent" && <div className="inline-alert warning" role="status"><p>Chưa nhận được tín hiệu audio từ nguồn này. Phát thử audio hoặc chọn nguồn khác.</p><span>Kiểm tra nguồn hoặc chọn nguồn khác.</span></div>}
    {state === "unavailable" && selected && <div className="inline-alert destructive" role="alert"><p>Nguồn đã chọn không còn khả dụng. Capture đã dừng để tránh dùng nhầm thiết bị.</p><span>Chọn nguồn khác.</span></div>}
  </section>;
}
