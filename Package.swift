// swift-tools-version: 6.0
import PackageDescription

// Downloads use the LocalLM SDK, consumed as prebuilt binaries from the official GitHub release
// (https://github.com/ancientcomputing/locallm/releases/tag/v3.0.0-GA), the same way the SDK's own
// examples do. Checksums are the `.sha256` files published next to each zip.
let sdkVersion = "3.0.0-GA"
let sdkBase = "https://github.com/ancientcomputing/locallm/releases/download/v\(sdkVersion)"

let package = Package(
    name: "ModelShelf",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ModelShelf", targets: ["ModelShelf"]),
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: "\(sdkBase)/LocalLMLabSDKCore-\(sdkVersion).xcframework.zip",
            checksum: "2b286cfecae1f6596c64255d72550a30f6f3cfe8323e4aa2a5176a4275699451"
        ),
        .binaryTarget(
            name: "LocalLMLabSDKInference",
            url: "\(sdkBase)/LocalLMLabSDKInference-\(sdkVersion).xcframework.zip",
            checksum: "e89336700bba35a546967a66eb34e3fb59e44a8150758da44ec95a104047bd54"
        ),
        // Scanning, copying, verifying, logging. No SDK dependency, so its tests stay fast.
        .target(name: "ShelfCore"),
        // Re-downloads through the SDK's MLXModelProvider.
        .target(
            name: "ShelfDownload",
            dependencies: ["ShelfCore", "LocalLMLabSDKCore", "LocalLMLabSDKInference"]
        ),
        .executableTarget(
            name: "ModelShelf",
            dependencies: ["ShelfCore", "ShelfDownload"],
            linkerSettings: [
                // The SDK frameworks are dynamic: next to the binary for `swift run`,
                // in Contents/Frameworks inside the .app.
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"]),
        .testTarget(
            name: "ShelfDownloadTests",
            dependencies: ["ShelfDownload", "ShelfCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../.."])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
