// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcpmRuntime",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "AcpmRuntimeCore", targets: ["AcpmRuntimeCore"]),
        .executable(name: "AcpmRuntime", targets: ["AcpmRuntime"]),
    ],
    dependencies: [
        .package(path: "../../clients/swift"),
    ],
    targets: [
        .target(
            name: "AcpmRuntimeCore",
            dependencies: [
                .product(name: "AcpmClient", package: "swift"),
            ]
        ),
        .executableTarget(
            name: "AcpmRuntime",
            dependencies: [
                "AcpmRuntimeCore",
                .product(name: "AcpmClient", package: "swift"),
            ]
        ),
        .testTarget(
            name: "AcpmRuntimeTests",
            dependencies: [
                "AcpmRuntimeCore",
                .product(name: "AcpmClient", package: "swift"),
            ]
        ),
    ]
)
