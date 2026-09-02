// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SC6000Connect",
    platforms: [.macOS(.v13), .iOS(.v17)],
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
        // App aparte que simula reproductores en la red, para probar sin equipo.
        .executableTarget(
            name: "DJSimulatorApp",
            dependencies: ["StageLinqKit"],
            path: "Sources/DJSimulatorApp",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate")
            ]
        ),
    ]
)
