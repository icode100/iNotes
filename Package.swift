// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iNotes",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NotesCore", targets: ["NotesCore"]),
        .executable(name: "iNotes", targets: ["NotesApp"])
    ],
    targets: [
        .target(name: "NotesCore"),
        .executableTarget(name: "NotesApp", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"])
    ],
    swiftLanguageModes: [.v5]
)
