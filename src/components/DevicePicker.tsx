export type SourceKind = "input" | "desktopLoopback";
export type Endpoint = { kind: SourceKind; endpointId: string; displayName: string; availability: "active" | "unavailable" };
export type EndpointCatalogues = { inputs: Endpoint[]; desktopLoopback: Endpoint[] };
export type Source = Pick<Endpoint, "kind" | "endpointId" | "displayName">;
export type AudioLevel = { peakPercent: number; rmsPercent: number; state: "signal" | "silent" | "unavailable" };

type DevicePickerProps = { catalogues: EndpointCatalogues; selected?: Source; disabled: boolean; onChoose: (endpoint: Endpoint) => void; onRefresh: () => void };
const availabilityCopy: Record<Endpoint["availability"], string> = { active: "Sẵn sàng", unavailable: "Không khả dụng" };

function DeviceGroup({ heading, hint, devices, selected, disabled, onChoose, onRefresh }: { heading: string; hint?: string; devices: Endpoint[]; selected?: Source; disabled: boolean; onChoose: (endpoint: Endpoint) => void; onRefresh: () => void }) {
  return <section className="device-group" aria-labelledby={`${heading}-heading`}>
    <div className="section-title"><div><h2 id={`${heading}-heading`}>{heading}</h2>{hint && <p>{hint}</p>}</div><span className="device-count">{devices.length} thiết bị</span></div>
    {devices.length === 0 ? <div className="inline-alert" role="status"><p>Không tìm thấy thiết bị audio phù hợp. Kiểm tra thiết bị trong Windows rồi làm mới danh sách.</p><button className="quiet-button" type="button" onClick={onRefresh}>Làm mới danh sách</button></div> :
      <div className="device-list" role="radiogroup" aria-label={heading}>{devices.map((device) => {
        const checked = selected?.endpointId === device.endpointId && selected.kind === device.kind;
        const unavailable = device.availability === "unavailable";
        return <label className={`device-row${checked ? " is-selected" : ""}`} key={device.endpointId}>
          <input checked={checked} disabled={disabled || unavailable} name="audio-source" onChange={() => onChoose(device)} type="radio" value={device.endpointId} />
          <span className="device-copy"><span className="device-name">{device.displayName}</span><span className="device-meta">{device.kind === "desktopLoopback" ? "Loopback hệ thống · " : ""}{availabilityCopy[device.availability]}</span></span>
          <span className={`status-badge status-${device.availability}`}>{availabilityCopy[device.availability]}</span>
        </label>;
      })}</div>}
  </section>;
}

export function DevicePicker(props: DevicePickerProps) {
  return <div className="device-picker">
    <DeviceGroup devices={props.catalogues.inputs} disabled={props.disabled} heading="Microphone / Input" onChoose={props.onChoose} onRefresh={props.onRefresh} selected={props.selected} />
    <DeviceGroup devices={props.catalogues.desktopLoopback} disabled={props.disabled} heading="Desktop / System Audio" hint="Chọn một thiết bị render để ghi Loopback hệ thống; không cần Stereo Mix." onChoose={props.onChoose} onRefresh={props.onRefresh} selected={props.selected} />
  </div>;
}
