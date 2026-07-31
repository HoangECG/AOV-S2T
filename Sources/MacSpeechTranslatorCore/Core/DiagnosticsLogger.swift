import OSLog

/// Privacy-safe OSLog categories. Callers must never interpolate transcript
/// text, audio samples, or user-selected file paths into these messages.
public enum DiagnosticsLogger {
    private static let subsystem = "com.hoangecg.MacSpeechTranslator"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let vad = Logger(subsystem: subsystem, category: "vad")
    public static let asr = Logger(subsystem: subsystem, category: "asr")
    public static let transcript = Logger(subsystem: subsystem, category: "transcript")
    public static let translation = Logger(subsystem: subsystem, category: "translation")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let performance = Logger(subsystem: subsystem, category: "performance")
}
