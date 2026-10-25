// swift-tools-version: 6.0
import PackageDescription

// NollieCore holds what the phone and the Mac share: talking to a Hermes gateway and keeping
// chat state. It has no UI framework in it. Whatever is platform specific (the turn surface,
// local notices, push sign-up) reaches it through the protocols in Runtime/Hooks.swift.

let core = Target.target(
    name: "NollieCore",
    path: "Sources/NollieCore",
    resources: [.process("Characters/Resources")],
    swiftSettings: [.swiftLanguageMode(.v6)]
)

let package = Package(
    name: "NollieCore",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "NollieCore", targets: ["NollieCore"]),
    ],
    targets: [core]
)
