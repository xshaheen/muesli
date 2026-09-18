// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImlaNative",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .library(name: "ImlaCore", targets: ["ImlaCore"]),
        .library(name: "ImlaNativeAppCore", targets: ["ImlaNativeApp"]),
        .executable(name: "ImlaNativeApp", targets: ["ImlaNativeAppShell"]),
        .executable(name: "imla-cli", targets: ["ImlaCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        // Pinned to the commit fixing empty transcriptions when `promptTokens` are set
        // (argmaxinc PR #514) — vocabulary biasing returns "" on every decode without it.
        // TODO: move to a tagged release once one ships with that fix.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", revision: "97d09fd9790393579d2834e2bc098deb3e26bc06"),
        // Ghost Pepper uses this LLM.swift fork for local Qwen cleanup. Before production, replace it with upstream
        // eastriverlee/LLM.swift once explicit Qwen/ChatML template behavior is validated against our GGUF models.
        .package(url: "https://github.com/obra/LLM.swift.git", revision: "f1e1e11982dbc59662be191b8bed408dfb48e9df"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
        .package(url: "https://github.com/MimicScribe/dtln-aec-coreml.git", from: "0.4.0-beta"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "ImlaCore",
            dependencies: [],
            path: "Sources/ImlaCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "ImlaNativeApp",
            dependencies: [
                "ImlaCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "LLM", package: "LLM.swift"),
                .target(name: "CLiteRTLMBridge", condition: .when(platforms: [.macOS])),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DTLNAecCoreML", package: "dtln-aec-coreml"),
                .product(name: "DTLNAec512", package: "dtln-aec-coreml"),
                "AudioGraphExceptionBridge",
                "LocalVQEBridge",
            ],
            path: "Sources/ImlaNativeApp",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Contacts"),
                .linkedFramework("ContactsUI"),
            ]
        ),
        // Thin executable shell: main.swift + App Intents. Kept separate from
        // the existing ImlaNativeApp module so a genuine Xcode Application
        // target (see xcodegen project used for release builds) can wrap it
        // and get App Intents metadata extraction, which only runs for real
        // Application-type targets, not SwiftPM executables or libraries.
        .executableTarget(
            name: "ImlaNativeAppShell",
            dependencies: [
                "ImlaNativeApp",
            ],
            path: "Sources/ImlaNativeAppShell",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .executableTarget(
            name: "ImlaCLI",
            dependencies: [
                "ImlaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/ImlaCLI"
        ),
        .target(
            name: "AudioGraphExceptionBridge",
            path: "Sources/AudioGraphExceptionBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        .target(
            name: "LocalVQEBridge",
            path: "Sources/LocalVQEBridge",
            publicHeadersPath: "include"
        ),
        // Thin source wrapper that owns the CLiteRTLM module declaration.
        // This avoids a module.modulemap collision between CLiteRTLM_mac_lib and
        // FluidAudio's NemoTextProcessing xcframeworks when both are linked, as
        // the build system (SwiftPM/xcodebuild) flattens all xcframework headers
        // to the same include/ output dir and conflicts on the filename.
        .target(
            name: "CLiteRTLMBridge",
            dependencies: [
                .target(name: "CLiteRTLM_mac_lib", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/CLiteRTLMBridge",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "CLiteRTLM_mac_lib",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.13.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "ec9ffe230dc39117a7fc8933b1cc15910454027fee6d3041534ab7cf17313981"
        ),
        .testTarget(
            name: "ImlaTests",
            dependencies: ["ImlaNativeApp", "ImlaCore", "ImlaCLI", "AudioGraphExceptionBridge", "LocalVQEBridge"],
            path: "Tests/ImlaTests",
            resources: [
                .copy("Fixtures"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
