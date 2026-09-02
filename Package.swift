// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SC6000Connect",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "StageLinqKit",
            path: "Sources/StageLinqKit"
        ),
        .executableTarget(
            name: "SC6000ConnectApp",
            dependencies: ["StageLinqKit"],
            path: "Sources/SC6000ConnectApp"
        ),
    ]
)
