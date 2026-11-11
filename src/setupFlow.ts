import type { Source } from "./components/DevicePicker";

export type NativeInvoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

export type SetupSnapshot = {
  state: "ready" | "setupRequired" | "confirmationRequired" | "sourceUnavailable" | "blocked";
  source?: { kind: string; displayName: string; endpointId: string; endpointStatus: string };
  blockingChecks: string[];
  diagnostics: Record<string, string | number | null | undefined>;
  currentStep?: "model" | "benchmarkSample" | "benchmark" | "officialSource";
  canComplete?: boolean;
};

export type BenchmarkReport = {
  rows: BenchmarkResult[];
  profile?: { worker: string; workerBuild?: string; rtf?: number; p95Ms?: number; correctness?: number } | null;
  fallbackReason?: string | null;
};

export type BenchmarkResult = {
  worker: "cpu" | "cuda" | "vulkan";
  workerBuild?: string;
  correctness?: number;
  rtf?: number;
  p95Ms?: number;
  memoryBytes?: number;
  driver?: string;
  outcome: "passed" | "rejected" | "notInstalled";
  reason?: string;
};

type ResetCapture = () => void;

const reset = (callback?: ResetCapture) => callback?.();
const snapshot = (invoke: NativeInvoke) => invoke<SetupSnapshot>("setup_snapshot");

async function cancelBenchmark(invoke: NativeInvoke) {
  await invoke("cancel_benchmark_transaction");
}

export function initializeSetup(invoke: NativeInvoke) {
  return snapshot(invoke);
}

export async function acceptAndRunBenchmark(invoke: NativeInvoke, resetCapture?: ResetCapture) {
  try {
    const report = await invoke<BenchmarkReport>("finish_and_run_benchmark");
    if (!report.profile) throw new Error("Benchmark chưa tạo profile native đạt yêu cầu.");
    await invoke("accept_native_benchmark_profile");
    return { report, snapshot: await snapshot(invoke) };
  } catch (error) {
    await cancelBenchmark(invoke);
    throw error;
  } finally {
    reset(resetCapture);
  }
}

export async function retryBenchmark(invoke: NativeInvoke, resetCapture?: ResetCapture) {
  try {
    await cancelBenchmark(invoke);
    await invoke("retry_benchmark_recording");
  } finally {
    reset(resetCapture);
  }
}

export async function runOfficialSourceTest(invoke: NativeInvoke, source: Source, resetCapture?: ResetCapture) {
  try {
    await invoke("select_audio_source", { source });
    await invoke("set_current_official_source");
    await invoke("start_official_source_test");
    await invoke("finish_official_source_test");
    return await snapshot(invoke);
  } catch (error) {
    await cancelBenchmark(invoke);
    throw error;
  } finally {
    reset(resetCapture);
  }
}

export async function completeSetup(invoke: NativeInvoke, current: SetupSnapshot) {
  if (current.canComplete !== true) throw new Error("Native chưa cho phép hoàn tất thiết lập.");
  await invoke("complete_setup");
  return snapshot(invoke);
}

export async function cancelSetup(invoke: NativeInvoke, resetCapture?: ResetCapture) {
  try {
    await invoke("cancel_setup_transaction");
    return await snapshot(invoke);
  } finally {
    reset(resetCapture);
  }
}

export async function confirmRebenchmark(invoke: NativeInvoke) {
  await invoke("begin_setup_reconfiguration", { step: "benchmark" });
  return snapshot(invoke);
}
