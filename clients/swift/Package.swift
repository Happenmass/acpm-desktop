// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcpmClient",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "AcpmClient", targets: ["AcpmClient"]),
    ],
    targets: [
        .target(
            name: "AcpmClient"
        ),
        .testTarget(
            name: "AcpmClientTests",
            dependencies: ["AcpmClient"]
        ),
    ]
)
