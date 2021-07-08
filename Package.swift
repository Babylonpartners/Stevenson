// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "Stevenson",
    platforms: [
        .macOS(.v10_15),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", .upToNextMajor(from: "4.31.0"))
    ],
    targets: [
        .target(
            name: "Stevenson",
            dependencies: [.product(name: "Vapor", package: "vapor")]
        ),
        .target(
            name: "App",
            dependencies: [.target(name: "Stevenson")],
            swiftSettings: [
                // Enable better optimizations when building in Release configuration. Despite the use of
                // the `.unsafeFlags` construct required by SwiftPM, this flag is recommended for Release
                // builds. See <https://github.com/swift-server/guides#building-for-production> for details.
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ]
        ),
        .target(
            name: "Run",
            dependencies: [.target(name: "App")]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [.target(name: "App")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
