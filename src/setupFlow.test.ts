import { describe, expect, it, vi } from "vitest";
import {
  acceptAndRunBenchmark,
  cancelSetup,
  completeSetup,
  initializeSetup,
  retryBenchmark,
  runOfficialSourceTest,
  type NativeInvoke,
} from "./setupFlow";

const snapshot = { state: "setupRequired" as const, blockingChecks: [] as string[], diagnostics: {}, canComplete: false };

function native(results: Record<string, unknown> = {}): NativeInvoke {
  return vi.fn(async (command: string) => results[command] ?? snapshot) as NativeInvoke;
}

describe("setup flow", () => {
  it("runs the measured benchmark transaction and advances only with a native profile", async () => {
    const invoke = native({
      finish_and_run_benchmark: { rows: [{ worker: "cpu", outcome: "passed", workerBuild: "cpu", correctness: 1, rtf: 0.2, p95Ms: 400 }], profile: { worker: "cpu" } },
      setup_snapshot: { ...snapshot, currentStep: "officialSource" },
    });

    const result = await acceptAndRunBenchmark(invoke);

    expect(invoke).toHaveBeenCalledWith("finish_and_run_benchmark");
    expect(invoke).toHaveBeenCalledWith("accept_native_benchmark_profile");
    expect(invoke).toHaveBeenCalledWith("setup_snapshot");
    expect(result.report.profile).toEqual({ worker: "cpu" });
    expect(result.snapshot.currentStep).toBe("officialSource");
  });

  it("cleans up a rejected or failed sample and always unlocks UI capture", async () => {
    const invoke = native({ finish_and_run_benchmark: Promise.reject(new Error("silent")) });
    const resetCapture = vi.fn();

    await expect(acceptAndRunBenchmark(invoke, resetCapture)).rejects.toThrow("silent");

    expect(invoke).toHaveBeenCalledWith("cancel_benchmark_transaction");
    expect(resetCapture).toHaveBeenCalledOnce();
  });

  it("awaits cleanup before retrying a benchmark recording", async () => {
    const order: string[] = [];
    const invoke = vi.fn(async (command: string) => {
      order.push(command);
      return snapshot;
    }) as NativeInvoke;
    const resetCapture = vi.fn();

    await retryBenchmark(invoke, resetCapture);

    expect(order).toEqual(["cancel_benchmark_transaction", "retry_benchmark_recording"]);
    expect(resetCapture).toHaveBeenCalledOnce();
  });

  it("sends the exact official source selection before the signal and Vietnamese one-shot", async () => {
    const invoke = native({ setup_snapshot: { ...snapshot, canComplete: true } });

    await runOfficialSourceTest(invoke, { kind: "desktopLoopback", endpointId: "render-id", displayName: "Loa" });

    expect(invoke).toHaveBeenNthCalledWith(1, "select_audio_source", { source: { kind: "desktopLoopback", endpointId: "render-id", displayName: "Loa" } });
    expect(invoke).toHaveBeenNthCalledWith(2, "set_current_official_source");
    expect(invoke).toHaveBeenNthCalledWith(3, "start_official_source_test");
    expect(invoke).toHaveBeenNthCalledWith(4, "finish_official_source_test");
  });

  it("never requests completion from a local flag when native canComplete is false", async () => {
    const invoke = native({ setup_snapshot: snapshot });

    await expect(completeSetup(invoke, { ...snapshot, canComplete: false })).rejects.toThrow("chưa cho phép");
    expect(invoke).not.toHaveBeenCalledWith("complete_setup");
  });

  it("routes launch from the native snapshot and awaits cancellation cleanup", async () => {
    const invoke = native({ setup_snapshot: { ...snapshot, state: "ready" } });
    const resetCapture = vi.fn();

    expect((await initializeSetup(invoke)).state).toBe("ready");
    await cancelSetup(invoke, resetCapture);

    expect(invoke).toHaveBeenCalledWith("cancel_setup_transaction");
    expect(resetCapture).toHaveBeenCalledOnce();
  });
});
