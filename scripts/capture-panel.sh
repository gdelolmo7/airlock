#!/bin/zsh
# Capture Airlock's own windows, by window ID.
#
# Interactive capture does not work on this app. The panel is an LSUIElement
# overlay held open by the pointer, so ⌘⇧4 collapses the thing you are aiming
# at the moment you reach for the keyboard. `screencapture -l <id>` needs no
# focus and no click, so the panel stays exactly as it is.
#
#   zsh scripts/capture-panel.sh            # list Airlock's windows
#   zsh scripts/capture-panel.sh panel out.png    # capture the big one
#   zsh scripts/capture-panel.sh island out.png   # capture the compact island
#
# Needs Screen Recording for the terminal running it: System Settings ›
# Privacy & Security › Screen Recording. Without it every capture fails with
# "could not create image from window" — for ANY window, not just this app,
# which is how to tell a permission problem from an app-specific one.
set -euo pipefail

list() {
  swift -e '
import CoreGraphics
guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in l where ((w[kCGWindowOwnerName as String] as? String) ?? "").contains("Airlock") {
  let id = (w[kCGWindowNumber as String] as? Int) ?? -1
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let width = (b["Width"] as? Double) ?? 0, height = (b["Height"] as? Double) ?? 0
  print("\(id) \(Int(width)) \(Int(height))")
}'
}

if [[ $# -eq 0 ]]; then
  echo "Airlock windows (id width height):"
  list | while read -r id w h; do
    # The island is short and wide; the panel is everything else.
    [[ $h -lt 80 ]] && kind="island" || kind="panel"
    printf "  %-8s id=%-6s %sx%s\n" "$kind" "$id" "$w" "$h"
  done
  exit 0
fi

want="$1"; out="${2:-$want.png}"
id=$(list | while read -r i w h; do
  [[ $h -lt 80 && $want == island ]] && echo "$i"
  [[ $h -ge 80 && $want == panel ]] && echo "$i"
done | head -1)

[[ -n "$id" ]] || { echo "No '$want' window. Is Airlock running, and the panel open?" >&2; exit 1; }

# -x silences the shutter: capturing the panel is not an event the user asked for.
screencapture -x -l "$id" "$out"
echo "✓ $out  ($(du -h "$out" | cut -f1 | tr -d ' '))"
