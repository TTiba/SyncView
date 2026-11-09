// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SyncView",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SyncView",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/SyncView",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
