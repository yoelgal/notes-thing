// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "NotesThing",
  platforms: [.macOS(.v14)],
  dependencies: [
    // No NeMo text-normalization engine: it's for TTS, and its prebuilt Rust library fails to link on Xcode 26.6.
    .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.3", traits: []),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
  ],
  targets: [
    .executableTarget(
      name: "NotesThing",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      // scripts/build.sh puts Sparkle.framework in Contents/Frameworks.
      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
  ],
  swiftLanguageModes: [.v5]
)
