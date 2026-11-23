// swift-tools-version: 5.9
import PackageDescription
import Foundation

// GamePortKit (https://github.com/akinware/gameport) is used from a checkout next to this one when there is
// one (`../gameport`, or `../kopru`, its working name), so both can be changed together; otherwise from GitHub.
let localGamePort = ["../gameport", "../kopru"].first {
    FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + $0 + "/Package.swift")
}
let gamePortDependency: Package.Dependency = localGamePort.map { .package(path: $0) }
    ?? .package(url: "https://github.com/akinware/gameport.git", branch: "main")
let gamePortPackage = localGamePort.map { String($0.dropFirst(3)) } ?? "gameport"

let package = Package(
    name: "NXLibrary",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NXLibraryCore", targets: ["NXLibraryCore"]),
        .library(name: "ArcanePorting", targets: ["ArcanePorting"]),
        .executable(name: "NXLibrary", targets: ["NXLibrary"]),
    ],
    dependencies: [
        gamePortDependency,
    ],
    targets: [
        .target(name: "NXLibraryCore", path: "Sources/NXLibraryCore", resources: [.process("Resources")]),
        .target(name: "ArcanePorting", dependencies: ["NXLibraryCore"], path: "Sources/ArcanePorting"),
        .executableTarget(
            name: "NXLibrary",
            dependencies: [
                "NXLibraryCore",
                "ArcanePorting",
                .product(name: "GamePortKit", package: gamePortPackage),
            ],
            path: "Sources/NXLibrary"
        ),
        .testTarget(
            name: "NXLibraryCoreTests",
            dependencies: ["NXLibraryCore"],
            path: "Tests/NXLibraryCoreTests"
        ),
        .testTarget(
            name: "ArcanePortingTests",
            dependencies: ["NXLibraryCore", "ArcanePorting"],
            path: "Tests/ArcanePortingTests"
        ),
    ]
)
