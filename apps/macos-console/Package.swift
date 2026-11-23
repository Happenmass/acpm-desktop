// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcpmRuntime",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "AcpmRuntime", targets: ["AcpmRuntime"]),
    ],
    dependencies: [
        .package(path: "../../clients/swift"),
    ],
    targets: [
        .executableTarget(
            name: "AcpmRuntime",
            dependencies: [
                .product(name: "AcpmClient", package: "swift"),
            ]
        ),
    ]
)
