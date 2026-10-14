// swift-tools-version: 6.0
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

// Human acceptance tests and real-daemon tests have explicit entry points. Their source stays
// in the ordinary test targets, but the default package run contains only tests that need no
// person and no separately started daemon.
let manualAcceptanceEnabled =
    ProcessInfo.processInfo.environment["COMPANION_MANUAL_ACCEPTANCE"] == "1"
let e2eAcceptanceEnabled =
    ProcessInfo.processInfo.environment["COMPANION_E2E_ACCEPTANCE"] == "1"
let manualAcceptanceSettings: [SwiftSetting] = manualAcceptanceEnabled
    ? [.define("COMPANION_MANUAL_ACCEPTANCE")]
    : []
let e2eAcceptanceSettings: [SwiftSetting] = e2eAcceptanceEnabled
    ? [.define("COMPANION_E2E_ACCEPTANCE")]
    : []

// Two platforms, and only the protocol and the mobile models are built for both. The iOS app
// under `CompanionIOS/` links exactly those two products; the shell targets — AppKit, the
// wakeword archive — are never built for iOS because nothing on that side asks for them.
let package = Package(
    name: "companion-mac",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "companion-mac", targets: ["CompanionMac"]),
        .library(name: "CompanionProtocol", targets: ["CompanionProtocol"]),
        .library(name: "CompanionMobile", targets: ["CompanionMobile"]),
        .library(name: "CompanionFigure", targets: ["CompanionFigure"]),
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

        // What the iOS app shows, without a single view: the paired machines and their
        // connections, the session list with its filter and grouping, the chat, the voice
        // turn. Free of SwiftUI and of both platforms, so `swift test` on the Mac covers it.
        .target(name: "CompanionMobile", dependencies: ["CompanionProtocol", "CompanionFigure"]),

        // The figure: its states, the frames that are drawn for them, the alpha mask the hit
        // test uses. Its own target rather than a folder inside the shell, because
        // `DESIGN.md` section Mobil, Technik der Clients has the app take the figure over from
        // the desktop shells — and the shell is AppKit and never builds for a phone. Nothing
        // in here is AppKit: Core Graphics and ImageIO are on both platforms.
        .target(name: "CompanionFigure"),

        // Overlay panel, panels, menu bar item.
        .target(
            name: "CompanionUI",
            dependencies: ["CompanionProtocol", "CompanionWakeword", "CompanionFigure"]),

        .executableTarget(name: "CompanionMac", dependencies: ["CompanionUI"]),

        // The shell binary's own command line. A test target may depend on an executable
        // target; `Options` lives in its own file next to `main.swift` so the top-level
        // code of the binary is not what the tests reach for.
        .testTarget(name: "CompanionMacTests", dependencies: ["CompanionMac"]),
        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"]),
        .testTarget(
            name: "CompanionMobileTests", dependencies: ["CompanionMobile"],
            swiftSettings: e2eAcceptanceSettings),
        .testTarget(name: "CompanionFigureTests", dependencies: ["CompanionFigure"]),
        .testTarget(
            name: "CompanionUITests", dependencies: ["CompanionUI"],
            swiftSettings: manualAcceptanceSettings + e2eAcceptanceSettings),
        .testTarget(name: "CompanionWakewordTests", dependencies: ["CompanionWakeword"]),
    ]
)
