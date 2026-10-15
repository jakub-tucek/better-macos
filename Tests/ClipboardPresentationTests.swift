import AppKit
import ClipboardPolicy

func runClipboardPresentationTests() {
    let text = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", text: "Displayed\n\tphrase " + String(repeating: "x", count: 300) + " hidden\n tail", image: nil, pinned: false)
    let image = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", text: nil, image: Data([1]), pinned: false)
    expect(ClipboardPresentation.rows([text], query: "displayed phrase").count == 1, "search matches normalized displayed phrase across newline and tab")
    expect(ClipboardPresentation.rows([text], query: "hidden tail").count == 1, "search includes normalized content beyond truncated preview")
    expect(ClipboardPresentation.rows([text], query: " displayed\n phrase ").count == 1, "search normalizes query whitespace too")
    expect(ClipboardPresentation.rows([image], query: "PNG image").count == 1, "search matches displayed PNG kind")
}

func runClipboardThumbnailTests() {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    let entry = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", text: nil, image: bitmap.representation(using: .png, properties: [:])!, pinned: false)
    let cache = ClipboardThumbnails()
    expect(cache.image(for: entry) == nil, "thumbnail request returns immediately without synchronous image decoding")
    func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(predicate(), "bounded thumbnail worker completes before test deadline")
    }
    wait { cache.inFlightCount == 0 }
    expect(cache.image(for: entry) != nil && cache.decodes == 1, "asynchronous thumbnail becomes cached on main thread")
    let png = entry.image!
    var huge = png
    huge.replaceSubrange(16..<24, with: [0, 1, 0, 0, 0, 1, 0, 0]) // 65,536 squared; header only, no huge allocation.
    var wide = png
    wide.replaceSubrange(16..<20, with: [0, 0, 32, 1]) // 8,193 edge.
    var area = png
    area.replaceSubrange(16..<24, with: [0, 0, 32, 0, 0, 0, 32, 0]) // 8,192 squared exceeds pixel budget.
    var zero = png; zero.replaceSubrange(16..<20, with: [0, 0, 0, 0])
    expect(!ClipboardThumbnails.admits(huge) && !ClipboardThumbnails.admits(wide) && !ClipboardThumbnails.admits(area) && !ClipboardThumbnails.admits(zero), "PNG header preflight rejects huge dimensions, area, zero edges before ImageIO")
    expect(ClipboardThumbnails.decodePNG(huge) == nil, "real decoder rejects a synthetic huge PNG header without allocating its pixels")
    func item(_ data: Data, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, created: Date(), source: "fixture", text: nil, image: data, pinned: false)
    }
    let rejected = ClipboardThumbnails(decode: { _ in fatalError("Rejected PNG must never reach worker decoder") })
    _ = rejected.image(for: item(huge))
    expect(rejected.decodes == 0 && rejected.cachedCount == 1, "rejected dimensions cache failure without dispatching a decode")
    for _ in 0..<100 { _ = rejected.image(for: item(Data([1]))) }
    expect(rejected.cachedCount == ClipboardThumbnails.cacheLimit, "success and failure cache has a strict 48-entry bound")

    let cgImage = ClipboardThumbnails.decodePNG(png)!
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var active = 0, peak = 0, workerOnMain = false
    let blocked = ClipboardThumbnails(decode: { _ in
        lock.lock(); active += 1; peak = max(peak, active); workerOnMain = workerOnMain || Thread.isMainThread; lock.unlock()
        started.signal(); release.wait()
        lock.lock(); active -= 1; lock.unlock()
        finished.signal(); return cgImage
    })
    var callbacks: [UUID] = []
    blocked.onReady = { id in expect(Thread.isMainThread, "thumbnail completion is delivered on main thread"); callbacks.append(id) }
    let entries = (0..<12).map { _ in item(png) }
    blocked.retain(entries)
    for entry in entries { _ = blocked.image(for: entry); _ = blocked.image(for: entry) }
    expect(started.wait(timeout: .now() + 2) == .success && started.wait(timeout: .now() + 2) == .success, "two thumbnail workers can start independently")
    expect(blocked.inFlightCount == ClipboardThumbnails.requestLimit && blocked.decodes == ClipboardThumbnails.requestLimit, "duplicate requests deduplicate and pending work is capped at eight")
    var heartbeat = false
    DispatchQueue.main.async { heartbeat = true }
    wait { heartbeat }
    lock.lock(); let boundedWorkers = peak == 2 && !workerOnMain; lock.unlock()
    expect(boundedWorkers, "blocked image decoders leave UI responsive and never exceed two background workers")
    blocked.retain([]) // deletion cancels running and queued jobs before they can publish.
    release.signal(); release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success && finished.wait(timeout: .now() + 2) == .success, "canceled running decoders can finish safely")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    expect(callbacks.isEmpty && blocked.cachedCount == 0 && blocked.inFlightCount == 0, "deleted/canceled late results cannot repopulate cache or notify UI")
    lock.lock(); let queuedCanceled = active == 0; lock.unlock()
    expect(queuedCanceled, "canceled queued jobs never enter the decoder after running jobs finish")

    let sourceStarted = DispatchSemaphore(value: 0), sourceRelease = DispatchSemaphore(value: 0)
    let replacement = ClipboardThumbnails(decode: { _ in sourceStarted.signal(); sourceRelease.wait(); return cgImage })
    let old = item(png), new = item(png + Data([0]), id: old.id)
    var completions = 0
    replacement.onReady = { _ in
        expect(Thread.isMainThread, "current thumbnail completion is delivered on the main thread")
        completions += 1
    }
    _ = replacement.image(for: old)
    expect(sourceStarted.wait(timeout: .now() + 2) == .success, "old payload decode starts")
    replacement.retain([new]); _ = replacement.image(for: new)
    expect(sourceStarted.wait(timeout: .now() + 2) == .success, "new payload with same entry identity starts its own request")
    sourceRelease.signal(); sourceRelease.signal()
    wait { replacement.inFlightCount == 0 }
    expect(completions == 1 && replacement.image(for: new) != nil, "same-ID changed-source late result is ignored and only current payload publishes")
    replacement.clear()
    expect(replacement.cachedCount == 0, "Clear releases all cached thumbnails")

    let failed = ClipboardThumbnails(decode: { _ in nil })
    _ = failed.image(for: entry); wait { failed.inFlightCount == 0 }
    _ = failed.image(for: entry); _ = failed.image(for: entry)
    expect(failed.decodes == 1 && failed.cachedCount == 1, "asynchronous decode failure is cached and not retried on every render")

    let oversizedPixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let oversizedImage = oversizedPixels.cgImage
    let oversized = ClipboardThumbnails(decode: { _ in oversizedImage })
    _ = oversized.image(for: entry); wait { oversized.inFlightCount == 0 }
    expect(oversized.image(for: entry) == nil && oversized.decodes == 1, "oversized worker output is rejected and cached as failure")

    let capacityGate = DispatchSemaphore(value: 0)
    let capacity = ClipboardThumbnails(decode: { _ in capacityGate.wait(); return cgImage })
    let capacityEntries = (0..<20).map { _ in item(png) }
    for entry in capacityEntries { _ = capacity.image(for: entry) }
    expect(capacity.inFlightCount == 8 && capacity.deferredCount == 8, "submitted and deferred request queues each have a strict eight-entry bound")
    for _ in capacityEntries { capacityGate.signal() }
    wait { capacity.decodes == 16 && capacity.inFlightCount == 0 && capacity.deferredCount == 0 }
    expect(capacity.image(for: capacityEntries.last!) != nil, "recent requests deferred at worker capacity resume automatically without another render")
}
