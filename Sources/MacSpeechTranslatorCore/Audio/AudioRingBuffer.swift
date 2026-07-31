import Foundation
import AudioToolbox

/// A bounded single-producer/single-consumer buffer. Writes drop the oldest
/// samples when full so a live capture always prefers the most recent audio.
public final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var sampleCount = 0
    private var overruns = 0
    private var underruns = 0

    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.storage = Array(repeating: 0, count: max(capacity, 1))
    }

    public var availableSamples: Int {
        lock.withLock { sampleCount }
    }

    public var overrunCount: Int {
        lock.withLock { overruns }
    }

    public var underrunCount: Int {
        lock.withLock { underruns }
    }

    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// This method performs no heap allocation and is safe to call from an
    /// audio render callback. The lock is held only while copying samples.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard !samples.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            if sampleCount == capacity {
                readIndex = (readIndex + 1) % capacity
                sampleCount -= 1
                overruns += 1
            }
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            sampleCount += 1
        }
        return samples.count
    }

    /// Copies planar Core Audio buffers into interleaved storage without an
    /// intermediate allocation. The caller owns the source pointers.
    @discardableResult
    public func writeNonInterleaved(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Int {
        guard channelCount > 0, frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        var written = 0
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let source = channels[channel]
                if sampleCount == capacity {
                    readIndex = (readIndex + 1) % capacity
                    sampleCount -= 1
                    overruns += 1
                }
                storage[writeIndex] = source[frame]
                writeIndex = (writeIndex + 1) % capacity
                sampleCount += 1
                written += 1
            }
        }
        return written
    }

    /// Copies a planar AudioBufferList directly. This avoids allocating an
    /// array of channel pointers in ScreenCaptureKit's output callback.
    @discardableResult
    public func writePlanar(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        frameCount: Int
    ) -> Int {
        guard channelCount > 0, frameCount > 0, buffers.count >= channelCount else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        var written = 0
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                guard let rawData = buffers[channel].mData else { continue }
                let source = rawData.assumingMemoryBound(to: Float.self)
                if sampleCount == capacity {
                    readIndex = (readIndex + 1) % capacity
                    sampleCount -= 1
                    overruns += 1
                }
                storage[writeIndex] = source[frame]
                writeIndex = (writeIndex + 1) % capacity
                sampleCount += 1
                written += 1
            }
        }
        return written
    }

    public func read(maximumSamples: Int) -> [Float] {
        guard maximumSamples > 0 else { return [] }
        // Allocate on the consumer path before taking the lock so the audio
        // callback cannot wait behind array growth or append bookkeeping.
        var output = Array(repeating: Float.zero, count: maximumSamples)
        lock.lock()

        let amount = min(maximumSamples, sampleCount)
        guard amount > 0 else {
            underruns += 1
            lock.unlock()
            return []
        }

        for index in 0..<amount {
            output[index] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        sampleCount -= amount
        lock.unlock()
        if amount < output.count { output.removeLast(output.count - amount) }
        return output
    }

    public func reset() {
        lock.withLock {
            readIndex = 0
            writeIndex = 0
            sampleCount = 0
            overruns = 0
            underruns = 0
        }
    }
}
