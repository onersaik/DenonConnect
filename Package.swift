// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SC6000Connect",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "StageLinqKit",
            path: "Sources/StageLinqKit",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "SC6000ConnectApp",
            dependencies: ["StageLinqKit"],
            path: "Sources/SC6000ConnectApp",
            linkerSettings: [
                .linkedFramework("Network"),
            ]
        ),
        // App aparte que simula reproductores en la red, para probar sin equipo.
        .executableTarget(
            name: "DJSimulatorApp",
            dependencies: ["StageLinqKit"],
            path: "Sources/DJSimulatorApp"
        ),
    ]
)
