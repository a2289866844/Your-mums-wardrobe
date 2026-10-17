// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tendedero",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.17.0")
    ],
    targets: [
        .target(
            name: "ClipdCore",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Tendedero",
            dependencies: ["ClipdCore", .product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "Sources/Tendedero",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TendederoTests",
            dependencies: ["Tendedero", "ClipdCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClipdCoreTests",
            dependencies: ["ClipdCore", .product(name: "SQLCipher", package: "SQLCipher.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
