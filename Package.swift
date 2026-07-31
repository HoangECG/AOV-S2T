// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSpeechTranslator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacSpeechTranslatorCore", targets: ["MacSpeechTranslatorCore"]),
        .executable(name: "MacSpeechTranslator", targets: ["MacSpeechTranslatorApp"]),
        .executable(name: "MacSpeechTranslatorCoreChecks", targets: ["MacSpeechTranslatorCoreChecks"])
    ],
    targets: [
        .target(
            name: "MacSpeechTranslatorCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Translation"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MacSpeechTranslatorApp",
            dependencies: ["MacSpeechTranslatorCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "MacSpeechTranslatorCoreChecks",
            dependencies: ["MacSpeechTranslatorCore"],
            path: "Tests/MacSpeechTranslatorCoreChecks"
        )
    ],
    swiftLanguageModes: [.v6]
)
