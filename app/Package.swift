// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path to the vendored libDF dylib, computed from the manifest location so
// `swift build` works regardless of the invoking working directory.
let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let dfLibDir = pkgDir + "/../engine/CDeepFilter/lib"

let dfLinker: LinkerSetting = .unsafeFlags([
    "-L\(dfLibDir)",
    "-ldf",
    // dev run: find dylib in the vendored dir; bundled run: Resources/lib
    "-Xlinker", "-rpath", "-Xlinker", dfLibDir,
    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Resources/lib"
])

let package = Package(
    name: "CrispApp",
    platforms: [
        .macOS(.v13)   // PRD: macOS 13 Ventura 이상
    ],
    targets: [
        .target(
            name: "CDeepFilter",
            path: "Sources/CDeepFilter",
            publicHeadersPath: "include"
        ),
        // Pure DSP/model layer (no AVFoundation) — shared by the app and the verifier.
        .target(
            name: "CrispEngine",
            dependencies: ["CDeepFilter"],
            path: "Sources/CrispEngine"
        ),
        .executableTarget(
            name: "CrispApp",
            dependencies: ["CrispEngine", "CDeepFilter"],
            path: "Sources/CrispApp",
            linkerSettings: [dfLinker]
        ),
        .executableTarget(
            name: "dftool",
            dependencies: ["CrispEngine", "CDeepFilter"],
            path: "Sources/dftool",
            linkerSettings: [dfLinker]
        ),
        .executableTarget(
            name: "filetool",
            dependencies: ["CrispEngine", "CDeepFilter"],
            path: "Sources/filetool",
            linkerSettings: [dfLinker]
        ),
        .executableTarget(
            name: "mictool",
            dependencies: ["CrispEngine", "CDeepFilter"],
            path: "Sources/mictool",
            linkerSettings: [dfLinker]
        ),
        // Verifies the Voice Enhancer DSP stage + pipeline (streaming determinism, RTF).
        .executableTarget(
            name: "vetool",
            dependencies: ["CrispEngine", "CDeepFilter"],
            path: "Sources/vetool",
            linkerSettings: [dfLinker]
        )
    ]
)
