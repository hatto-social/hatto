// macOS stand-in for clipset.c: puts typed data on the general pasteboard. usage: swift setclip.swift <case> <fixturesDir>
// cases: file | text | filetext | png | png_html | truncated | random | hugedims | huge120   (UNTESTED on a Mac by Dmitry)
import AppKit
let a = CommandLine.arguments; let c = a[1]; let fx = a[2].hasSuffix("/") ? a[2] : a[2] + "/"
let pb = NSPasteboard.general; pb.clearContents()
func data(_ n: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: fx + n)) }
switch c {
case "file": pb.writeObjects([URL(fileURLWithPath: fx + "red.png") as NSURL])
case "text": pb.setString("/some/path/not/a/file.png", forType: .string)
case "filetext": pb.writeObjects([URL(fileURLWithPath: fx + "red.png") as NSURL]); pb.addTypes([.string], owner: nil); pb.setString("/some/path/not/a/file.png", forType: .string)
case "png": pb.setData(data("red.png"), forType: .png)
case "png_html": pb.setData(data("red.png"), forType: .png); pb.setString("<meta charset=\"utf-8\"><img src=\"https://example.com/a.png\" alt=\"x\">", forType: .html)
case "truncated": pb.setData(data("truncated.png"), forType: .png)
case "random": pb.setData(data("random.png"), forType: .png)
case "hugedims": pb.setData(data("huge_dims.png"), forType: .png)
case "huge120": pb.setData(data("huge_120mb.bin"), forType: .png)
default: print("unknown case"); exit(1)
}
print("clipboard set:", c, pb.types?.map { $0.rawValue } ?? [])
