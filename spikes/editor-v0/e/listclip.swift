// Lists NSPasteboard item types after a copy. usage: swift listclip.swift
// Not run on a Mac in the spike. See the runbook section G.
import AppKit
let pb = NSPasteboard.general
print("changeCount:", pb.changeCount, " items:", pb.pasteboardItems?.count ?? 0)
for (i, it) in (pb.pasteboardItems ?? []).enumerated() {
  print("-- item \(i)")
  for t in it.types {
    let d = it.data(forType: t)
    print("   \(t.rawValue)  \(d?.count ?? -1) bytes")
  }
}
