// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The screen guide is private: the public copy of this code is exported
// without any folder named `Guide` (scripts/export-public.sh). When those
// folders are here, the guide is compiled in and `AIRLOCK_GUIDE` is defined;
// when they are not, every `#if AIRLOCK_GUIDE` falls away and the same
// package builds the app without it. Nothing else decides — the files being
// present is the switch.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasGuide = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent("Sources/AirlockCore/Guide").path)
let guideFlag: [SwiftSetting] = hasGuide ? [.define("AIRLOCK_GUIDE")] : []

// Tools that only make sense with the guide: the owner's cost report and the
// replay bench. Absent from the public package along with their folders.
let guideTools: [Target] = hasGuide ? [
    // Prints the guide's cost, speed and hit rate from the owner's logs.
    // A tool for the owner, like PromptProbe and LicenseTool: never in the bundle.
    .executableTarget(
        name: "GuideReport",
        dependencies: ["AirlockCore"],
        swiftSettings: guideFlag
    ),

    // Sends the owner's saved looks again, cheaper, and prints whether
    // they still name the same button. Spends money on the owner's key,
    // so it sends nothing without --go. Never in the bundle.
    .executableTarget(
        name: "GuideReplay",
        dependencies: ["AirlockCore"],
        swiftSettings: guideFlag
    ),
] : []

let package = Package(
    name: "AgenticNotch",
    // macOS 26+ only. The product needs a physical notch, which means a
    // MacBook Pro 2021+ or Air 2022+ — every one of them Apple Silicon, and
    // every Apple Silicon Mac runs 26. So this excludes nobody whose hardware
    // would have worked, only people choosing not to update, and it buys an
    // unconditional Liquid Glass identity plus one OS version to verify instead
    // of three.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AirlockApp", targets: ["AirlockApp"]),
        .executable(name: "airlock-hook", targets: ["NotchHook"]),
        .executable(name: "airlock-setup", targets: ["NotchSetup"]),
        .library(name: "AirlockCore", targets: ["AirlockCore"]),
    ],
    // ONE external dependency, and the rule it breaks is worth restating.
    //
    // Everything else is vendored (DynamicNotchKit, see THIRD-PARTY-LICENSES.txt)
    // or written here. Sparkle is the exception because an auto-updater is the
    // single most security-sensitive component an app outside the App Store can
    // have: it downloads code and runs it. Hand-rolling that is how you ship a
    // remote-code-execution path, and vendoring it means owning the job of
    // tracking its security fixes by hand. Sparkle is the audited standard,
    // it is MIT, and it is the one place where "use the boring thing everyone
    // has reviewed" beats "no dependencies".
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Shared, UI-free library: domain model, reducer, wire protocol, transport, agent registry.
        .target(name: "AirlockCore", swiftSettings: guideFlag),


        // The `@Generable` schema the model fills in, shared by the app and the
        // probe so the probe measures the type that ships. Deliberately NOT in
        // Core: `NotchHook` depends on Core, and `FoundationModels` has no
        // business linked into a fail-open CLI that runs on every tool call.
        .target(name: "AirlockGenerable", dependencies: ["AirlockCore"], swiftSettings: guideFlag),

        // The package's only Objective-C, and as little of it as works: a
        // `@try`/`@catch` around the AVFAudio calls that raise instead of
        // throwing. Swift cannot catch an `NSException`, and one escaping a
        // main-actor job crashed 1.0.12 twice — moments later, in unrelated
        // code. See `ALExceptionCatcher.h` and `AudioCapture`.
        .target(name: "AirlockObjC"),

        // SwiftUI + AppKit shell — the menu-bar/notch app.
        .executableTarget(
            name: "AirlockApp",
            dependencies: [
                "AirlockCore",
                "AirlockGenerable",
                "AirlockObjC",
                "DynamicNotchKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: guideFlag
        ),

        // Tiny fail-open CLI invoked by agent hooks. Forwards stdin → bridge.
        .executableTarget(
            name: "NotchHook",
            dependencies: ["AirlockCore"]
        ),

        // Scores the assistant's instructions against the cases in
        // `PromptEvaluation`. NOT a test target on purpose: it needs a language
        // model, which makes it slow and unavailable with Apple Intelligence off,
        // and `swift test` has to stay fast and hermetic. The grading half is
        // pure and IS tested there. Never embedded in the app — the packaging
        // script copies three named binaries and this is not one of them.
        .executableTarget(
            name: "PromptProbe",
            dependencies: ["AirlockCore", "AirlockGenerable"],
            swiftSettings: guideFlag
        ),

        // Issues and inspects licence keys. NOT a test target and never in the
        // bundle: the app only VERIFIES, which is the point of an asymmetric
        // scheme — the signing half lives wherever orders are fulfilled.
        .executableTarget(
            name: "LicenseTool",
            dependencies: ["AirlockCore"]
        ),

        // Installer CLI: wires an agent's config to call the hook binary.
        .executableTarget(
            name: "NotchSetup",
            dependencies: ["AirlockCore"]
        ),

        // Vendored, not a dependency — see THIRD-PARTY-LICENSES.txt.
        .target(name: "DynamicNotchKit"),

        // Test-only helpers shared by both test suites: a scratch directory and
        // a throwaway defaults suite, each of which deletes itself. Nothing but
        // the tests links it. It is a target rather than a copy in each suite
        // because the two copies would drift, and the thing they promise —
        // that a test run leaves nothing outside the build folder — is not the
        // kind of promise to keep in two places.
        .target(name: "AirlockTestSupport", path: "Tests/Support"),

        .testTarget(
            name: "AirlockCoreTests",
            dependencies: ["AirlockCore", "AirlockTestSupport"],
            swiftSettings: guideFlag
        ),

        .testTarget(
            name: "AirlockAppTests",
            dependencies: ["AirlockApp", "AirlockObjC", "AirlockTestSupport"],
            swiftSettings: guideFlag
        ),
    ] + guideTools
)
