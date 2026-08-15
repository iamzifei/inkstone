// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkstoneCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "InkstoneCore", targets: ["InkstoneCore"]),
    ],
    dependencies: [
        // Apple's cmark-gfm based Markdown parser. Gives us GitHub Flavored Markdown
        // (tables, strikethrough, task lists, autolinks) for free; Obsidian-specific
        // syntax (wikilinks, highlights, callouts, block refs) is layered on top.
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        // YAML parsing for note frontmatter.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "InkstoneCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                "Yams",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InkstoneCoreTests",
            dependencies: ["InkstoneCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
