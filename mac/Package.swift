// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import PackageDescription

// Where the wakeword static library is looked for. `Scripts/build-wakeword.sh` builds
// `companion-wakeword-ffi` with cargo and copies the archive into `Vendor/`; SwiftPM cannot
// build Rust itself, so the archive has to exist before `swift build` links anything. An
// absolute path because a relative -L would resolve against whatever directory the linker
// happens to run in.
let vendorDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor")
    .path

let package = Package(
    name: "companion-mac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "companion-mac", targets: ["CompanionMac"]),
        .library(name: "CompanionProtocol", targets: ["CompanionProtocol"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
        .library(name: "CompanionWakeword", targets: ["CompanionWakeword"]),
    ],
    targets: [
        // Placeholder daemon protocol. Swapped for generated types once
        // app/protocol/schema/*.json is final; see Sources/CompanionProtocol/README.md.
        .target(name: "CompanionProtocol"),

        // The C ABI of app/crates/companion-wakeword-ffi. Nothing but a module map; the
        // header it names lives with the Rust crate that implements it.
        .systemLibrary(name: "CWakeword", path: "Sources/CWakeword"),

        // Swift over that ABI: the detector, the training call, and where models are kept.
        .target(
            name: "CompanionWakeword",
            dependencies: ["CWakeword", "CompanionProtocol"],
            linkerSettings: [.unsafeFlags(["-L\(vendorDirectory)"])]),

        // Overlay panel, figure, panels, menu bar item.
        .target(name: "CompanionUI", dependencies: ["CompanionProtocol", "CompanionWakeword"]),

        .executableTarget(name: "CompanionMac", dependencies: ["CompanionUI"]),

        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"]),
        .testTarget(name: "CompanionUITests", dependencies: ["CompanionUI"]),
        .testTarget(name: "CompanionWakewordTests", dependencies: ["CompanionWakeword"]),
    ]
)
