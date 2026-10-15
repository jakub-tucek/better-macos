// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FixMacOSPolicy",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ClipboardPolicy", type: .static, targets: ["ClipboardPolicy"])],
    targets: [
        // Explicit ownership: sibling App/Core/SharedUI/feature sources are not package inputs.
        .target(name: "ClipboardPolicy", path: "Sources/Features/Clipboard/Policy"),
        .testTarget(name: "ClipboardPolicyTests", dependencies: ["ClipboardPolicy"], path: "Tests/ClipboardPolicyTests")
    ],
    swiftLanguageModes: [.v5]
)
