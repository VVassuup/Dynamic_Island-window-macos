// swift-tools-version:5.9
// Dynamic Island для macOS — порт оригинального приложения для Windows (created by @vvassuup).
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DynamicIsland",
            path: "Sources/DynamicIsland",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
