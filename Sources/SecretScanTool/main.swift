import Foundation
import SecretScan

// Looks through a finished app for anything shaped like a secret key.
//
//   swift run SecretScanTool output/package/Airlock.app
//   swift run SecretScanTool output/package/Airlock.app --allow 3f9a0c1b2d4e
//
// Exits 0 when nothing was found, 1 when something was, 2 when it could not
// look. release.sh runs it between packaging and notarizing, so a bundle that
// carries a key stops on this Mac.
//
// It never prints what it found: a finding is a place, a kind, a length and a
// fingerprint. `--allow <fingerprint>` lets one false alarm through on
// purpose, by that fingerprint, so the release script can name it without the
// matched text being written down anywhere. The public keys the app is meant
// to carry need no `--allow`: they are read from the bundle's own Info.plist
// (`SecretScan.publicByName`).

func stop(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var fingerprints: Set<String> = []
while let flag = arguments.firstIndex(of: "--allow") {
    guard flag + 1 < arguments.count else { stop("--allow must be followed by a fingerprint") }
    fingerprints.insert(arguments[flag + 1].lowercased())
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 1 else {
    stop("usage: SecretScanTool <path to the .app> [--allow <fingerprint>]…")
}

let report: SecretScan.Report
do {
    report = try SecretScan.scan(bundle: URL(fileURLWithPath: arguments[0]), allowing: fingerprints)
} catch {
    stop("couldn't look through \(arguments[0]): \(error.localizedDescription)")
}
for line in report.lines { print("  \(line)") }
exit(report.isClean ? 0 : 1)
