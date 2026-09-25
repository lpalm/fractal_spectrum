// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FractalSpectrum",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "FractalSpectrum", targets: ["FractalSpectrum"]),
        .executable(name: "fscli", targets: ["fscli"]),
    ],
    targets: [
        .target(
            name: "CFractal",
            cSettings: [.unsafeFlags(["-O3", "-I/opt/homebrew/include"])],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "/opt/homebrew/lib/libmpfr.a",
                "-Xlinker", "/opt/homebrew/lib/libgmp.a",
            ])]
        ),
        .target(
            name: "FractalKit",
            dependencies: ["CFractal"],
            exclude: ["Shaders"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(name: "FractalSpectrum", dependencies: ["FractalKit"]),
        .executableTarget(name: "fscli", dependencies: ["FractalKit"]),
    ],
    swiftLanguageModes: [.v5]
)
