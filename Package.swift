// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Where an app keeps its data: folder sizes, moving a folder to another disk, clones,
        // JSON files saved a moment after the last change, and secrets in the Keychain. No SwiftUI.
        .library(name: "FileKit", targets: ["FileKit"]),
    ],
    targets: [
        .target(name: "FileKit"),
        .testTarget(name: "FileKitTests", dependencies: ["FileKit"]),
    ]
)
