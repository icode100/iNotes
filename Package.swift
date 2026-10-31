// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iNotes",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NotesCore", targets: ["NotesCore"]),
        .executable(name: "iNotes", targets: ["NotesApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "NotesCore"),
        .executableTarget(
            name: "NotesApp",
            dependencies: [
                "NotesCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"])
    ],
    swiftLanguageModes: [.v5]
)
