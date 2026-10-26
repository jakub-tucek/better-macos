import AppKit
import SwiftUI

protocol FeatureTestSuite {
    static func run() throws
    static func render(directory: String?) throws
}
extension FeatureTestSuite {
    static func render(directory: String?) throws {}
}

/// Hidden-window fixture. Views must use injected owners and isolated preferences.
func renderFeatureFixture<V: View>(_ view: V, name: String, directory: String?, dark: Bool, width: CGFloat = 1000, height: CGFloat = 820) throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(rootView: view)
    window.contentView = hosting
    defer { window.orderOut(nil) }
    for _ in 0..<4 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let directory else { return }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: root.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
}
