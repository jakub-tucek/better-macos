import AppKit

func runClipboardPresentationTests() {
    let text = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", text: "Displayed\n\tphrase " + String(repeating: "x", count: 300) + " hidden\n tail", image: nil, pinned: false)
    let image = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", text: nil, image: Data([1]), pinned: false)
    expect(ClipboardPresentation.rows([text], query: "displayed phrase").count == 1, "search matches normalized displayed phrase across newline and tab")
    expect(ClipboardPresentation.rows([text], query: "hidden tail").count == 1, "search includes normalized content beyond truncated preview")
    expect(ClipboardPresentation.rows([text], query: " displayed\n phrase ").count == 1, "search normalizes query whitespace too")
    expect(ClipboardPresentation.rows([image], query: "PNG image").count == 1, "search matches displayed PNG kind")
}
