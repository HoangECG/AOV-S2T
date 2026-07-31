import Foundation

public actor DefaultSentenceFinalizer: SentenceFinalizing {
    private let segmenter: VietnameseSentenceSegmenter

    public init(segmenter: VietnameseSentenceSegmenter = VietnameseSentenceSegmenter()) {
        self.segmenter = segmenter
    }

    public func finalize(text: String, startTime: TimeInterval, endTime: TimeInterval) -> [FinalizedSentence] {
        let sentences = segmenter.sentences(in: text)
        guard !sentences.isEmpty else { return [] }
        let duration = max(endTime - startTime, 0)
        let totalWeight = max(sentences.reduce(0) { $0 + $1.count }, 1)
        var cursor = startTime

        return sentences.enumerated().map { index, sentence in
            let sentenceDuration: TimeInterval
            if index == sentences.count - 1 {
                sentenceDuration = max(endTime - cursor, 0)
            } else {
                sentenceDuration = duration * Double(sentence.count) / Double(totalWeight)
            }
            let finalized = FinalizedSentence(text: sentence, startTime: cursor, endTime: cursor + sentenceDuration)
            cursor += sentenceDuration
            return finalized
        }
    }
}
