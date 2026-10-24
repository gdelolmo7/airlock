// swift-tools-version: 6.0
import PackageDescription

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
    // TWO external dependencies, and the rule they break is worth restating.
    //
    // Everything else is vendored (DynamicNotchKit, FluidDiarizer and
    // libwebp's encoder, see THIRD-PARTY-LICENSES.txt) or written here. Sparkle is the exception because an auto-updater is the
    // single most security-sensitive component an app outside the App Store can
    // have: it downloads code and runs it. Hand-rolling that is how you ship a
    // remote-code-execution path, and vendoring it means owning the job of
    // tracking its security fixes by hand. Sparkle is the audited standard,
    // it is MIT, and it is the one place where "use the boring thing everyone
    // has reviewed" beats "no dependencies".
    //
    // Sentry is the second, for crash reports, and only with the person's OK
    // (see `CrashReporter`). A crash handler has to run inside a process that
    // is already falling over: async-signal-safe writes, Mach exception ports,
    // a report finished before the process is gone. That is the same kind of
    // code as an updater, easy to get subtly wrong and impossible to test from
    // the outside, so the reviewed one wins again. It is MIT, and pinned to an
    // exact release, so a new version only arrives on purpose. The `Sentry`
    // product is the static build: nothing new is embedded in the bundle or
    // signed on its own, and a build without a DSN never starts it.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.26.1"),
    ],
    targets: [
        // Shared, UI-free library: domain model, reducer, wire protocol, transport, agent registry.
        .target(name: "AirlockCore"),


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
                "AirlockObjC",
                "AirlockEcho",
                "DynamicNotchKit",
                "FluidDiarizer",
                "CWebP",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),

        // Tiny fail-open CLI invoked by agent hooks. Forwards stdin → bridge.
        .executableTarget(
            name: "NotchHook",
            dependencies: ["AirlockCore"]
        ),

        // Runs the call-voices model over sound files and prints who spoke
        // when, what it cost, and how the lines would be numbered. A tool for
        // the owner: it needs the downloaded model, so it is
        // not a test, and it is never in the bundle.
        .executableTarget(
            name: "SpeakerProbe",
            dependencies: ["AirlockCore", "FluidDiarizer"]
        ),

        // Runs the echo remover over a recording of the microphone and of what
        // the speakers played, and prints what it took out and the delay it
        // found; with --transcribe, what the recogniser makes of each. A tool
        // for the owner like SpeakerProbe, never in the bundle.
        .executableTarget(
            name: "EchoProbe",
            dependencies: ["AirlockEcho"]
        ),

        // Issues and inspects licence keys. NOT a test target and never in the
        // bundle: the app only VERIFIES, which is the point of an asymmetric
        // scheme — the signing half lives wherever orders are fulfilled.
        .executableTarget(
            name: "LicenseTool",
            dependencies: ["AirlockCore"]
        ),

        // Looks through a finished app for anything shaped like a secret key;
        // release.sh runs it before notarizing, so a bundle carrying one never
        // leaves the Mac. Its own target so the tests reach the rules without
        // the app, and never in the bundle: its prefixes would be in the very
        // binary it scans.
        .target(name: "SecretScan"),
        .executableTarget(
            name: "SecretScanTool",
            dependencies: ["SecretScan"]
        ),

        // Installer CLI: wires an agent's config to call the hook binary.
        .executableTarget(
            name: "NotchSetup",
            dependencies: ["AirlockCore"]
        ),

        // Vendored, not a dependency — see THIRD-PARTY-LICENSES.txt.
        .target(name: "DynamicNotchKit"),

        // Google's WebP encoder, vendored as C source (BSD, see
        // THIRD-PARTY-LICENSES.txt and Sources/CWebP/README.md): macOS reads
        // WebP and cannot write it. Only the app links it. The include path is
        // the target's own folder because libwebp names its headers from
        // there ("src/dsp/dsp.h"); its licence files and README are not source.
        .target(
            name: "CWebP",
            exclude: ["COPYING", "PATENTS", "README.md"],
            cSettings: [.headerSearchPath(".")]
        ),

        // Takes the speakers' sound out of the microphone on a call, so that
        // on speakers the other side is not written down as you. Plain sound
        // maths over Accelerate, nothing of the app's: a target of its own so
        // its tests run without building the app.
        .target(name: "AirlockEcho"),

        // Tells the voices on the other side of a call apart (who spoke when,
        // never who they are). Vendored from FluidAudio, trimmed to the one
        // model it runs; the model itself is downloaded, not in the bundle.
        // See THIRD-PARTY-LICENSES.txt.
        .target(name: "FluidDiarizer"),

        // Test-only helpers shared by both test suites: a scratch directory and
        // a throwaway defaults suite, each of which deletes itself. Nothing but
        // the tests links it. It is a target rather than a copy in each suite
        // because the two copies would drift, and the thing they promise —
        // that a test run leaves nothing outside the build folder — is not the
        // kind of promise to keep in two places.
        .target(name: "AirlockTestSupport", path: "Tests/Support"),

        .testTarget(
            name: "AirlockCoreTests",
            dependencies: ["AirlockCore", "AirlockTestSupport"]
        ),

        .testTarget(
            name: "AirlockEchoTests",
            dependencies: ["AirlockEcho"]
        ),

        .testTarget(
            name: "SecretScanTests",
            dependencies: ["SecretScan", "AirlockTestSupport"]
        ),

        .testTarget(
            name: "AirlockAppTests",
            dependencies: ["AirlockApp", "AirlockObjC", "AirlockTestSupport"]
        ),
    ]
)
