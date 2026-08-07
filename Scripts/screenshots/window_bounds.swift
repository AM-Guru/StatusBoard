// Print the on-screen bounds of an app's windows, largest first.
//
//     swift window_bounds.swift "Status Board"
//
// Used by the App Store screenshot pipeline to crop a full-display capture
// down to just the app window. AppleScript would be the obvious tool, but
// System Events needs Accessibility permission and hangs waiting for it in a
// non-interactive session; CGWindowList needs no permission at all.

import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Status Board"

guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("could not read the window list\n".data(using: .utf8)!)
    exit(1)
}

struct Found {
    var number: Int
    var name: String
    var x: Int, y: Int, w: Int, h: Int
    var area: Int { w * h }
}

var found: [Found] = []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == wanted else { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
          let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
          w > 200, h > 200 else { continue }
    found.append(Found(number: window[kCGWindowNumber as String] as? Int ?? 0,
                       name: window[kCGWindowName as String] as? String ?? "",
                       x: Int(x), y: Int(y), w: Int(w), h: Int(h)))
}

for f in found.sorted(by: { $0.area > $1.area }) {
    print("\(f.number)\t\(f.x)\t\(f.y)\t\(f.w)\t\(f.h)\t\(f.name)")
}
