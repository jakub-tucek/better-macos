import AppKit

func runMenuBarUpdateTests() {
    let model = DashboardModel()
    var queued: [() -> Void] = []
    let updates = MenuBarUpdates(schedule: { queued.append($0) })
    var renders = 0
    var lastStatus = ""
    let observation = model.objectWillChange.sink {
        updates.request { renders += 1; lastStatus = model.audioStatus }
    }
    defer { observation.cancel() }
    for index in 0..<100 { model.audioStatus = "State \(index)" }
    expect(queued.count == 1 && renders == 0, "100 dashboard publications queue only one deferred status refresh")
    queued.removeFirst()()
    expect(renders == 1 && lastStatus == "State 99", "coalesced refresh reads committed latest state after willChange")
    model.audioStatus = "Next turn"
    expect(queued.count == 1, "a later turn can schedule another status update")
    queued.removeFirst()()
    expect(lastStatus == "Next turn", "subsequent updates are never permanently suppressed")

    model.watchdogReady = true
    let normal = updates.image(for: model, description: "Normal")
    expect(normal != nil, "normal status icon renders")
    for index in 0..<100 { model.audioStatus = "Unrelated \(index)" }
    expect(updates.image(for: model, description: "Normal") === normal,
           "unrelated publications reuse the existing image instead of redrawing")
    model.keepAwakeActive = true
    let awake = updates.image(for: model, description: "Awake")
    expect(awake != nil && awake !== normal, "awake state changes the cached icon")
    model.errorMessage = "Needs recovery"
    let warning = updates.image(for: model, description: "Attention")
    expect(warning != nil && warning !== awake, "attention state replaces the awake icon immediately")
    model.errorMessage = "Different recovery message"
    expect(updates.image(for: model, description: "Attention") === warning, "tooltip-only changes reuse the warning image")
    model.errorMessage = nil; model.keepAwakeActive = false
    let recovered = updates.image(for: model, description: "Normal")
    expect(recovered != nil && recovered !== warning, "cleared warning returns to the normal icon")
    expect(updates.image(for: model, description: "Changed accessible name") !== recovered,
           "accessibility description changes invalidate the cached image")
}
