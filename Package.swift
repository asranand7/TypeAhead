// swift-tools-version: 5.9
import PackageDescription

// Mirrors VimText's layout: a Core library holding the engine, and a thin
// executable that only wires up NSApplication. The split is what lets the
// predictor be unit-tested without AppKit or an event tap.
let package = Package(
    name: "TypeAhead",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "TypeAheadCore",
            path: "Core",
            // The memory store is SQLite, and the export format is the database
            // file itself — so the schema stays inspectable with the `sqlite3` CLI.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TypeAhead",
            dependencies: ["TypeAheadCore"],
            path: "App"
        ),
        // Diagnoses a live store: what has been learned, and what it would
        // actually suggest. Separates "nothing learned" from "learned but gated"
        // from "suggesting fine but the overlay is not visible".
        .executableTarget(
            name: "typeahead-doctor",
            dependencies: ["TypeAheadCore"],
            path: "Doctor"
        ),
        // Enables the input source through the Text Input Sources API, which is
        // what the "+" button in System Settings calls.
        .executableTarget(
            name: "typeahead-enable-im",
            dependencies: [],
            path: "EnableIM"
        ),
        // The input-method front-end: suggestions rendered inside the text field
        // as marked text. Shares the engine with the menu-bar app; only capture
        // and display differ.
        .executableTarget(
            name: "TypeAheadIM",
            dependencies: ["TypeAheadCore"],
            path: "InputMethod"
        ),
        // Renders the overlay alone, so the display path can be verified without
        // a trained store or a granted event tap.
        .executableTarget(
            name: "typeahead-overlay-demo",
            dependencies: ["TypeAheadCore"],
            path: "OverlayDemo"
        ),
        // An executable rather than a testTarget: XCTest ships with Xcode, and
        // this machine has only the Command Line Tools. VimText next door solves
        // it the same way. Run with `swift run TypeAheadTests`.
        .executableTarget(
            name: "TypeAheadTests",
            dependencies: ["TypeAheadCore"],
            path: "Tests/TypeAheadTests"
        )
    ]
)
