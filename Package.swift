// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

// The XCTest suite needs Xcode. Set AEROSPACE_SKIP_XCTEST=1 to build and run the remaining tests with the Command Line Tools only
let xcTestTargets: [Target] = Context.environment["AEROSPACE_SKIP_XCTEST"] == "1" ? [] : [
    .testTarget(
        name: "AppBundleTests",
        dependencies: [
            .target(name: "AppBundle"),
        ],
        swiftSettings: swiftSettings,
    ),
]

let package = Package(
    name: "AeroSpacePackage",
    // Runtime support for parameterized protocol types is only available in macOS 13.0.0 or newer
    // And it specifies deploymentTarget for CLI
    platforms: [.macOS(.v13)],
    // Products define the executables and libraries a package produces, making them visible to other packages.
    products: [
        .executable(name: "aerospace", targets: ["Cli"]),
        // Don't use this build for release, use xcode instead
        .executable(name: "AeroSpaceApp", targets: ["AeroSpaceApp"]),
        // We only need to expose this as a product for xcode
        .library(name: "AppBundle", targets: ["AppBundle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/InerziaSoft/ISSoundAdditions.git", exact: "2.0.1"),
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.4"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/soffes/HotKey.git", exact: "0.2.1"),
    ],
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    targets: [
        // Exposes the private _AXUIElementGetWindow function to swift
        .target(
            name: "PrivateApi",
            path: "Sources/PrivateApi",
            publicHeadersPath: "include",
        ),
        .target(
            name: "Common",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
            ],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "AppBundle",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "HotKey", package: "HotKey"),
                .product(name: "ISSoundAdditions", package: "ISSoundAdditions"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                .target(name: "Common"),
                .target(name: "PrivateApi"),
            ],
            swiftSettings: swiftSettings,
        ),
        .executableTarget(
            name: "AeroSpaceApp",
            dependencies: [
                .target(name: "AppBundle"),
            ],
            swiftSettings: swiftSettings,
        ),
        .executableTarget(
            name: "Cli",
            dependencies: [
                .target(name: "Common"),
            ],
            swiftSettings: swiftSettings,
        ),
        // Dev-only: opens the keybinding editor on a scratch config without starting the window manager
        .executableTarget(
            name: "KeybindingEditorPreview",
            dependencies: [
                .target(name: "AppBundle"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "KeybindingEditorTests",
            dependencies: [
                .target(name: "AppBundle"),
            ],
            swiftSettings: swiftSettings,
        ),
        // swift-testing suite for the workspace layouts (dwindle, floating): runs with the Command Line Tools alone
        .testTarget(
            name: "WorkspaceLayoutTests",
            dependencies: [
                .target(name: "AppBundle"),
            ],
            swiftSettings: swiftSettings,
        ),
    ] + xcTestTargets,
)
