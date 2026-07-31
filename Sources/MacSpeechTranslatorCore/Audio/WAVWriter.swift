import Foundation

public enum WAVWriter {
    public static func data(samples: [Float], sampleRate: Int = 16_000) throws -> Data {
        guard sampleRate > 0 else { throw MacSpeechTranslatorError.invalidAudioFormat }

        let pcm = samples.map { sample -> Int16 in
            let clamped = min(max(sample, -1), 1)
            return Int16((clamped * Float(Int16.max)).rounded())
        }
        let dataSize = pcm.count * MemoryLayout<Int16>.size
        let byteRate = sampleRate * MemoryLayout<Int16>.size
        let blockAlign = MemoryLayout<Int16>.size
        var result = Data()
        result.reserveCapacity(44 + dataSize)

        result.append("RIFF".data(using: .ascii) ?? Data())
        result.append(littleEndian: UInt32(36 + dataSize))
        result.append("WAVEfmt ".data(using: .ascii) ?? Data())
        result.append(littleEndian: UInt32(16))
        result.append(littleEndian: UInt16(1))
        result.append(littleEndian: UInt16(1))
        result.append(littleEndian: UInt32(sampleRate))
        result.append(littleEndian: UInt32(byteRate))
        result.append(littleEndian: UInt16(blockAlign))
        result.append(littleEndian: UInt16(16))
        result.append("data".data(using: .ascii) ?? Data())
        result.append(littleEndian: UInt32(dataSize))
        pcm.withUnsafeBufferPointer { buffer in
            result.append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
        return result
    }

    public static func write(samples: [Float], sampleRate: Int = 16_000, to url: URL) throws {
        try data(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
