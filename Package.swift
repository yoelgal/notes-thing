// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "NotesThing",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.5"),
  ],
  targets: [
    .executableTarget(
      name: "NotesThing",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
    ),
  ]
)
