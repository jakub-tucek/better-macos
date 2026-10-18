import Foundation

private final class LevelSink: DiagnosticSink {
    var lines: [Data] = []
    func write(_ line: Data) throws { lines.append(line) }
    var records: [[String: Any]] { lines.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
}

func runLevelChild(directory: String, domain: String) -> Bool {
    let logger = Diagnostics(sink: RotatingDiagnosticSink(directory: URL(fileURLWithPath: directory), session: UUID().uuidString, pid: getpid()),
        loadConfiguration: {
            DiagnosticConfiguration.resolve(environment: ProcessInfo.processInfo.environment["MAC_UTILS_LOG_LEVEL"],
                preference: UserDefaults(suiteName: domain)?.string(forKey: DiagnosticConfiguration.preferenceKey))
        })
    logger.emit("process", "startup", fields: ["process_role": "command_or_helper"])
    logger.emit("test", "helper_trace", level: .trace)
    return logger.flushForTesting()
}

func runLevelRegressions() throws {
    try check(DiagnosticConfiguration.resolve(environment: nil, preference: nil).level == .info, "normal logging defaults to info")
    try check(DiagnosticLevel.parse(" ALL \n") == .trace && DiagnosticLevel.parse("DEBUG") == .debug, "all aliases trace; parsing is case insensitive and trims whitespace")
    let config = DiagnosticConfiguration.resolve(environment: "error", preference: "all")
    try check(config.level == .error && config.source == "environment", "valid environment overrides saved logging preference")
    let fallback = DiagnosticConfiguration.resolve(environment: "NEVER_LOG_CONFIG_SECRET", preference: "all")
    try check(fallback.level == .trace && fallback.source == "preference" && fallback.invalidEnvironment, "invalid environment falls back to saved preference")
    let invalid = DiagnosticConfiguration.resolve(environment: "bad", preference: "bad")
    try check(invalid.level == .info && invalid.invalidEnvironment && invalid.invalidPreference && !invalid.fields.values.contains("bad"), "invalid values use info and report only sanitized flags")
    for threshold in DiagnosticLevel.allCases {
        let sink = LevelSink()
        let filtered = Diagnostics(sink: sink, minimumLevel: threshold)
        for level in DiagnosticLevel.allCases { filtered.emit("test", level.rawValue, level: level) }
        filtered.emit("process", "startup")
        try check(filtered.flushForTesting(), "threshold \(threshold.rawValue) drains")
        let levels = sink.records.filter { $0["category"] as? String == "test" }.compactMap { $0["severity"] as? String }
        try check(levels == DiagnosticLevel.allCases.filter { $0.rank >= threshold.rank }.map(\.rawValue), "threshold \(threshold.rawValue) delivers exact levels in order")
        let fields = sink.records.last?["fields"] as? [String: String]
        try check(fields?["effective_log_level"] == threshold.rawValue, "startup explains effective threshold even when info is filtered")
    }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let sink = LevelSink()
    let logger = Diagnostics(sink: sink, capacity: 4, loadConfiguration: {
        entered.signal(); release.wait()
        return DiagnosticConfiguration.resolve(environment: nil, preference: "all")
    })
    defer { release.signal() }
    logger.emit("process", "startup")
    try check(entered.wait(timeout: .now() + 5) == .success, "configuration reaches injected worker gate")
    for _ in 0..<1000 { logger.emit("test", "trace", level: .trace) }
    try check(logger.deliveryStateForTesting.outstanding == 4 && logger.deliveryStateForTesting.dropped == 997, "blocked preference loader preserves bounded nonblocking admission at all verbosity")
    release.signal()
    try check(logger.flushForTesting() && sink.records.count == 4, "worker resolves preference once and retains admitted trace events")
    let fields = sink.records.first?["fields"] as? [String: String]
    try check(fields?["effective_log_level"] == "trace" && fields?["log_level_source"] == "preference", "startup identifies all preference as trace")
    let strictSink = LevelSink(), strictEntered = DispatchSemaphore(value: 0), strictRelease = DispatchSemaphore(value: 0)
    let strict = Diagnostics(sink: strictSink, loadConfiguration: {
        strictEntered.signal(); strictRelease.wait()
        return DiagnosticConfiguration.resolve(environment: "error", preference: nil)
    })
    defer { strictRelease.signal() }
    strict.emit("process", "startup")
    try check(strictEntered.wait(timeout: .now() + 5) == .success, "strict configuration reaches worker gate")
    strict.emit("test", "pending_trace", level: .trace)
    strictRelease.signal()
    try check(strict.flushForTesting() && strictSink.records.count == 1, "worker filters below-threshold records admitted before configuration resolves")
    for _ in 0..<1000 { strict.emit("test", "filtered_trace", level: .trace) }
    try check(strict.deliveryStateForTesting.outstanding == 0 && strict.deliveryStateForTesting.dropped == 0, "resolved threshold rejects trace without consuming queue capacity or overflow count")
    let host = HostTransactions(diagnostics: logger)
    let decision = host.requestQuit(.init(isBusy: { true }, prepareMouse: { true }, quiesce: {}, prepareClipboard: { true },
        needsDisplayRecovery: { false }, restoreDisplays: { _ in }, suspendSpaces: nil, resumeClipboard: {},
        restoreSpacesChoice: {}, didReopen: {}, didVeto: { _ in }), reply: { _ in })
    try check(decision == .cancel && host.acceptsActions && logger.flushForTesting(), "logging preserves busy quit veto and reopened admission")
    let requested = sink.records.first { $0["event"] as? String == "quit_requested" }
    let vetoed = sink.records.first { $0["event"] as? String == "quit_vetoed" }
    try check(requested?["operation"] as? String == vetoed?["operation"] as? String && vetoed?["severity"] as? String == "warning" &&
        (vetoed?["fields"] as? [String: String])?["reason"] == "busy", "host rejection logs correlated warning with closed busy reason")
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "fixmacos.logging-child.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("all", forKey: DiagnosticConfiguration.preferenceKey)
    defer { defaults.removePersistentDomain(forName: suite) }
    for override in ["error", "all", "invalid"] {
        let directory = root.appendingPathComponent("child-\(override)")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--logging-child", directory.path, suite]
        var environment = ProcessInfo.processInfo.environment
        environment["MAC_UTILS_LOG_LEVEL"] = override
        child.environment = environment
        try child.run(); child.waitUntilExit()
        try check(child.terminationStatus == 0, "isolated child drains inherited \(override) configuration")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        let text = try urls.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        try check(text.contains("helper_trace") == (override != "error"), "child uses environment override or same saved logging key without changing other preferences")
        try check(text.contains("\"log_level_source\":\"\(override == "invalid" ? "preference" : "environment")\""), "child startup identifies actual configuration source")
    }
    let rotating = RotatingDiagnosticSink(directory: root.appendingPathComponent("logs"), session: UUID().uuidString, pid: getpid(), limit: 1024)
    let verbose = Diagnostics(sink: rotating, minimumLevel: .trace)
    for _ in 0..<40 {
        verbose.emit("test", "trace", level: .trace, fields: ["safe_count": String(repeating: "1", count: 350)])
        try check(verbose.flushForTesting(), "verbose real-file rotation drains")
    }
    let files = try FileManager.default.contentsOfDirectory(at: rotating.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    try check(files.count == 3 && files.allSatisfy { ((try? Data(contentsOf: $0).count) ?? Int.max) <= 1024 }, "trace records rotate within unchanged real-file limits")
}
