// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "companion-mac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "companion-mac", targets: ["CompanionMac"]),
        .library(name: "CompanionProtocol", targets: ["CompanionProtocol"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
    ],
    targets: [
        // Placeholder daemon protocol. Swapped for generated types once
        // app/protocol/schema/*.json is final; see Sources/CompanionProtocol/README.md.
        .target(name: "CompanionProtocol"),

        // Overlay panel, figure, panels, menu bar item.
        .target(name: "CompanionUI", dependencies: ["CompanionProtocol"]),

        .executableTarget(name: "CompanionMac", dependencies: ["CompanionUI"]),

        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"]),
        .testTarget(name: "CompanionUITests", dependencies: ["CompanionUI"]),
    ]
)
