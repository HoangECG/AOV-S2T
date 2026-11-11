[CmdletBinding()]
param(
    [switch]$ListOnly,
    [ValidateSet("Input", "RenderLoopback")]
    [string]$SourceKind,
    [string]$EndpointId,
    [switch]$RequireSignal,
    [switch]$WaitForInvalidation,
    [switch]$VerifyDefaultChange
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This acceptance harness requires Windows Core Audio."
}

if (-not ("WindowsAudioSmoke.WindowsAudioEndpoint" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace WindowsAudioSmoke {
    public enum DataFlow { Render = 0, Capture = 1 }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(DataFlow dataFlow, uint stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(DataFlow dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsctx, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
        [PreserveSig] int GetId(out IntPtr id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        [PreserveSig] int Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public sealed class WindowsAudioEndpoint {
        public string SourceKind { get; set; }
        public string EndpointId { get; set; }
        public string Availability { get; set; }
    }

    public sealed class WindowsAudioEvidence {
        public string State { get; set; }
        public float PeakPercent { get; set; }
        public float RmsPercent { get; set; }
        public string Detail { get; set; }
    }

    public static class EndpointCatalogue {
        private const uint DeviceStateAll = 0xF;
        private const uint DeviceStateActive = 0x1;
        private const int AUDCLNT_SHAREMODE_SHARED = 0;
        private const uint AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000;
        private const uint AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;

        public static WindowsAudioEndpoint[] List() {
            var endpoints = new List<WindowsAudioEndpoint>();
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            Add(endpoints, enumerator, DataFlow.Capture, "Input");
            Add(endpoints, enumerator, DataFlow.Render, "RenderLoopback");
            return endpoints.ToArray();
        }

        public static string DefaultId(string sourceKind) {
            var flow = sourceKind == "Input" ? DataFlow.Capture : DataFlow.Render;
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            Check(enumerator.GetDefaultAudioEndpoint(flow, 0, out device), "GetDefaultAudioEndpoint");
            return Id(device);
        }

        public static WindowsAudioEvidence Smoke(string sourceKind, string endpointId, int durationMilliseconds) {
            IntPtr format = IntPtr.Zero;
            IAudioClient client = null;
            try {
                var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                IMMDevice device;
                Check(enumerator.GetDevice(endpointId, out device), "GetDevice(exact endpoint ID)");
                Guid audioClientId = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
                object clientObject;
                Check(device.Activate(ref audioClientId, 23, IntPtr.Zero, out clientObject), "IMMDevice.Activate(IAudioClient)");
                client = (IAudioClient)clientObject;
                Check(client.GetMixFormat(out format), "IAudioClient.GetMixFormat");
                uint flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
                if (sourceKind == "RenderLoopback") flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
                Check(client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 0, 0, format, IntPtr.Zero), "IAudioClient.Initialize exact shared event endpoint");
                using (var packetReady = new AutoResetEvent(false)) {
                    Check(client.SetEventHandle(packetReady.SafeWaitHandle.DangerousGetHandle()), "IAudioClient.SetEventHandle");
                Guid captureClientId = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");
                object captureObject;
                Check(client.GetService(ref captureClientId, out captureObject), "IAudioClient.GetService(IAudioCaptureClient)");
                var capture = (IAudioCaptureClient)captureObject;
                short formatTag = Marshal.ReadInt16(format, 0);
                short blockAlign = Marshal.ReadInt16(format, 12);
                short bitsPerSample = Marshal.ReadInt16(format, 14);
                if (blockAlign <= 0 || bitsPerSample <= 0) throw new InvalidOperationException("invalid endpoint mix format");
                bool floatSamples = formatTag == 3 || (formatTag == -2 && Marshal.ReadInt32(format, 24) == 3);
                Check(client.Start(), "IAudioClient.Start");
                double peak = 0;
                double squareSum = 0;
                long samples = 0;
                int waited = 0;
                while (waited < durationMilliseconds) {
                    packetReady.WaitOne(50);
                    waited += 50;
                    uint packetFrames;
                    Check(capture.GetNextPacketSize(out packetFrames), "IAudioCaptureClient.GetNextPacketSize");
                    while (packetFrames > 0) {
                        IntPtr data;
                        uint frames, packetFlags;
                        ulong devicePosition, qpcPosition;
                        Check(capture.GetBuffer(out data, out frames, out packetFlags, out devicePosition, out qpcPosition), "IAudioCaptureClient.GetBuffer");
                        try {
                            if ((packetFlags & 0x2) == 0) {
                                int bytes = checked((int)(frames * (uint)blockAlign));
                                var packet = new byte[bytes];
                                Marshal.Copy(data, packet, 0, bytes);
                                int step = bitsPerSample / 8;
                                for (int offset = 0; offset + step <= packet.Length; offset += step) {
                                    double sample = Sample(packet, offset, bitsPerSample, floatSamples);
                                    sample = Math.Max(-1, Math.Min(1, sample));
                                    peak = Math.Max(peak, Math.Abs(sample));
                                    squareSum += sample * sample;
                                    samples++;
                                }
                            }
                        } finally {
                            Check(capture.ReleaseBuffer(frames), "IAudioCaptureClient.ReleaseBuffer");
                        }
                        Check(capture.GetNextPacketSize(out packetFrames), "IAudioCaptureClient.GetNextPacketSize");
                    }
                }
                Check(client.Stop(), "IAudioClient.Stop");
                return new WindowsAudioEvidence {
                    State = peak >= 0.01 ? "signal" : "silent",
                    PeakPercent = (float)(peak * 100),
                    RmsPercent = samples == 0 ? 0 : (float)(Math.Sqrt(squareSum / samples) * 100),
                    Detail = "exact endpoint opened; numeric PCM evidence only"
                };
                }
            } catch (Exception error) {
                return new WindowsAudioEvidence { State = "unavailable", PeakPercent = 0, RmsPercent = 0, Detail = error.GetType().Name };
            } finally {
                if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format);
                if (client != null) Marshal.ReleaseComObject(client);
            }
        }

        private static double Sample(byte[] bytes, int offset, int bits, bool isFloat) {
            if (isFloat && bits == 32) return BitConverter.ToSingle(bytes, offset);
            if (bits == 16) return BitConverter.ToInt16(bytes, offset) / 32768.0;
            if (bits == 24) {
                int value = bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;
                if ((value & 0x800000) != 0) value |= unchecked((int)0xff000000);
                return value / 8388608.0;
            }
            if (bits == 32) return BitConverter.ToInt32(bytes, offset) / 2147483648.0;
            throw new NotSupportedException("unsupported PCM bit depth");
        }

        private static void Add(List<WindowsAudioEndpoint> endpoints, IMMDeviceEnumerator enumerator, DataFlow flow, string sourceKind) {
            IMMDeviceCollection collection;
            Check(enumerator.EnumAudioEndpoints(flow, DeviceStateAll, out collection), "EnumAudioEndpoints");
            uint count;
            Check(collection.GetCount(out count), "IMMDeviceCollection.GetCount");
            for (uint index = 0; index < count; index++) {
                IMMDevice device;
                Check(collection.Item(index, out device), "IMMDeviceCollection.Item");
                uint state;
                Check(device.GetState(out state), "IMMDevice.GetState");
                endpoints.Add(new WindowsAudioEndpoint {
                    SourceKind = sourceKind,
                    EndpointId = Id(device),
                    Availability = (state & DeviceStateActive) != 0 ? "active" : "unavailable"
                });
            }
        }

        private static string Id(IMMDevice device) {
            IntPtr value;
            Check(device.GetId(out value), "IMMDevice.GetId");
            try { return Marshal.PtrToStringUni(value); }
            finally { Marshal.FreeCoTaskMem(value); }
        }

        private static void Check(int hresult, string operation) {
            if (hresult < 0) Marshal.ThrowExceptionForHR(hresult);
        }
    }
}
'@
}

$captureSource = Join-Path $PSScriptRoot "..\src-tauri\src\audio\capture.rs"
$sourceCode = Get-Content -Raw $captureSource
if ($sourceCode -notmatch 'get_device\(&source\.endpoint_id\)' -or
    $sourceCode -notmatch 'wasapi_capture_config\(source.kind\)' -or
    $sourceCode -notmatch 'client\.get_direction\(\) != config\.endpoint_direction' -or
    $sourceCode -notmatch '&config\.capture_direction' -or
    $sourceCode -notmatch 'CaptureStreamMode::EventsShared' -or
    $sourceCode -notmatch 'config\.stream_mode\(minimum_period\)' -or
    $sourceCode -notmatch 'set_get_eventhandle' -or
    $sourceCode -notmatch 'get_audiocaptureclient' -or
    $sourceCode -notmatch 'ShareMode::Shared' -or
    $sourceCode -notmatch 'TimingMode::Events') {
    throw "The native capture path no longer proves the exact shared/event capture contract."
}
if ($sourceCode -notmatch 'SourceKind::DesktopLoopback => WasapiCaptureConfig' -or
    $sourceCode -notmatch 'endpoint_direction: Direction::Render' -or
    $sourceCode -notmatch 'capture_direction: Direction::Capture' -or
    $sourceCode -notmatch 'Win32StreamFlags::EVENT_CALLBACK \| Win32StreamFlags::LOOPBACK') {
    throw "The selected-render loopback contract is missing or accepts playback direction."
}

$endpoints = [WindowsAudioSmoke.EndpointCatalogue]::List()
if ($ListOnly) {
    $endpoints |
        Select-Object SourceKind, EndpointId, Availability |
        Format-Table -AutoSize
    return
}

if ([string]::IsNullOrWhiteSpace($SourceKind) -or [string]::IsNullOrWhiteSpace($EndpointId)) {
    throw "Specify both -SourceKind and an exact -EndpointId. The harness never opens a Windows default endpoint."
}

$matches = @($endpoints | Where-Object { $_.SourceKind -eq $SourceKind -and $_.EndpointId -eq $EndpointId })
if ($matches.Count -ne 1) {
    throw "The supplied endpoint ID is missing or ambiguous for $SourceKind. Refusing fallback or default-device substitution."
}
if ($matches[0].Availability -ne "active") {
    throw "The supplied endpoint is unavailable. It was not opened and is not reported as passed."
}

$defaultBefore = [WindowsAudioSmoke.EndpointCatalogue]::DefaultId($SourceKind)
[pscustomobject]@{
    SourceKind = $SourceKind
    EndpointId = $EndpointId
    OpenMode = if ($SourceKind -eq "RenderLoopback") { "selected-render WASAPI loopback" } else { "selected input WASAPI capture" }
    DefaultEndpointBefore = $defaultBefore
    RawPcmPersisted = $false
    Result = "ready-for-manual-native-smoke"
} | Format-List

Write-Host "Open the local app, select only the supplied endpoint ID through its matching source group, then play known audio."
Write-Host "Record only peak/RMS percentage and state (signal, silent, or unavailable); do not save PCM or transcript content."
Read-Host "Start known audio (or leave it silent), then press Enter to open and meter the exact endpoint" | Out-Null
$evidence = [WindowsAudioSmoke.EndpointCatalogue]::Smoke($SourceKind, $EndpointId, 2500)
$evidence | Format-List
if ($evidence.State -eq "unavailable") {
    throw "The exact endpoint could not be opened. It was not replaced with a default endpoint."
}
if ($RequireSignal -and $evidence.State -ne "signal") {
    throw "The exact endpoint did not provide the required signal evidence."
}

if ($WaitForInvalidation) {
    Read-Host "The next 10-second exact-ID capture is starting. Disable or unplug the selected endpoint, then press Enter immediately" | Out-Null
    $lossEvidence = [WindowsAudioSmoke.EndpointCatalogue]::Smoke($SourceKind, $EndpointId, 10000)
    $lossEvidence | Format-List
    if ($lossEvidence.State -ne "unavailable") { throw "Invalidation was not observed; do not record this path as passed." }
    Write-Host "PASS: exact endpoint invalidation reported unavailable without source substitution."
}

if ($VerifyDefaultChange) {
    Read-Host "Change the Windows default for this source kind, then press Enter without changing the selected source" | Out-Null
    $defaultAfter = [WindowsAudioSmoke.EndpointCatalogue]::DefaultId($SourceKind)
    if ($defaultBefore -eq $defaultAfter) {
        throw "Windows default did not change; no-default-substitution was not proven."
    }
    $postDefaultEvidence = [WindowsAudioSmoke.EndpointCatalogue]::Smoke($SourceKind, $EndpointId, 2500)
    $postDefaultEvidence | Format-List
    if ($postDefaultEvidence.State -eq "unavailable") { throw "The specified endpoint became unavailable after the default change; it was not substituted." }
    if ($EndpointId -eq $defaultBefore -or $EndpointId -eq $defaultAfter) {
        throw "Choose a non-default endpoint to prove no default substitution."
    }
    Write-Host "PASS: the tested exact endpoint ID remains distinct from the Windows default before and after the change."
}
