import CoreLocation
import Foundation

struct RuntimeLogEntry: Codable, Identifiable, Equatable {
    enum Level: String, Codable {
        case debug
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let source: String
    let level: Level
    let category: String
    let message: String
    let details: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: String,
        level: Level,
        category: String,
        message: String,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }

    var renderedText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let localizedDetails = details.map {
            (localizedDiagnosticText($0.key), localizedDiagnosticValue($0.value))
        }
        let suffix = localizedDetails.isEmpty
            ? ""
            : "  " + localizedDetails.sorted(by: { $0.0 < $1.0 }).map { "\($0.0)=\($0.1)" }.joined(separator: "  ")
        return "\(formatter.string(from: timestamp)) [\(source)] [\(level.rawValue.uppercased())] [\(localizedCategory)] \(localizedMessage)\(suffix)"
    }

    var localizedCategory: String { localizedDiagnosticText(category) }
    var localizedMessage: String { localizedDiagnosticText(message) }

    var localizedDetailsText: String {
        details.map { (localizedDiagnosticText($0.key), localizedDiagnosticValue($0.value)) }
            .sorted(by: { $0.0 < $1.0 })
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }

    private func localizedDiagnosticText(_ text: String) -> String {
        AppLocalization.string(String.LocalizationValue(text))
    }

    private func localizedDiagnosticValue(_ value: String) -> String {
        switch value {
        case "true": return AppLocalization.string("是")
        case "false": return AppLocalization.string("否")
        default: return localizedDiagnosticText(value)
        }
    }
}

enum RuntimeLogStore {
    private static let lock = NSLock()
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
    private static let maximumBytes: UInt64 = 1_500_000
    static let retentionInterval: TimeInterval = 3 * 24 * 60 * 60
    private static let pruningInterval: TimeInterval = 60 * 60
    private static var lastPrunedAt: Date?

    static func append(_ entry: RuntimeLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let now = Date()
            try pruneExpiredLogsIfNeeded(now: now)
            guard entry.timestamp >= retentionCutoff(now: now) else { return }
            let url = try logURL(for: entry.source)
            try rotateIfNeeded(url)
            var data = try encoder.encode(entry)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
        } catch {
            NSLog("RuntimeLogStore append failed: %@", error.localizedDescription)
        }
    }

    static func loadAll(limit: Int = 800) -> [RuntimeLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let directory = logDirectory
        try? pruneExpiredLogs(in: directory, now: Date())
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let entries = urls
            .filter { $0.pathExtension == "jsonl" }
            .flatMap(readEntries)
            .sorted { $0.timestamp < $1.timestamp }
        return Array(entries.suffix(limit))
    }

    static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logDirectory)
        lastPrunedAt = nil
    }

    private static func logURL(for source: String) throws -> URL {
        let directory = logDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = (Bundle.main.bundleIdentifier ?? "unknown-process")
            .replacingOccurrences(of: "/", with: "-")
        let safeSource = source.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(process)-\(safeSource).jsonl")
    }

    private static var logDirectory: URL {
        AppGroup.containerURL.appendingPathComponent("RuntimeLogs", isDirectory: true)
    }

    static func retentionCutoff(now: Date) -> Date {
        now.addingTimeInterval(-retentionInterval)
    }

    private static func pruneExpiredLogsIfNeeded(now: Date) throws {
        if let lastPrunedAt,
           now >= lastPrunedAt,
           now.timeIntervalSince(lastPrunedAt) < pruningInterval {
            return
        }
        try pruneExpiredLogs(in: logDirectory, now: now)
    }

    private static func pruneExpiredLogs(in directory: URL, now: Date) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            lastPrunedAt = now
            return
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }

        for url in urls {
            let entries = readEntries(url)
            let retained = retainedEntries(entries, now: now)
            guard retained.count != entries.count else { continue }
            guard !retained.isEmpty else {
                try FileManager.default.removeItem(at: url)
                continue
            }
            var data = Data()
            for entry in retained {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: url, options: .atomic)
        }
        lastPrunedAt = now
    }

    static func retainedEntries(_ entries: [RuntimeLogEntry], now: Date) -> [RuntimeLogEntry] {
        let cutoff = retentionCutoff(now: now)
        return entries.filter { $0.timestamp >= cutoff }
    }

    private static func rotateIfNeeded(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maximumBytes else { return }
        let backup = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: url, to: backup)
    }

    private static func readEntries(_ url: URL) -> [RuntimeLogEntry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(RuntimeLogEntry.self, from: data)
        }
    }
}

enum RuntimeLogger {
    static func debug(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        write(.debug, source: source, category: category, message: message, details: details)
    }

    static func info(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        write(.info, source: source, category: category, message: message, details: details)
    }

    static func warning(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        write(.warning, source: source, category: category, message: message, details: details)
    }

    static func error(_ source: String, _ category: String, _ message: String, error: Error? = nil, details: [String: String] = [:]) {
        var values = details
        if let error {
            let nsError = error as NSError
            values["error.domain"] = nsError.domain
            values["error.code"] = String(nsError.code)
            values["error.description"] = nsError.localizedDescription
            if !nsError.userInfo.isEmpty {
                values["error.userInfo"] = nsError.userInfo
                    .map { "\($0.key)=\(String(describing: $0.value))" }
                    .sorted()
                    .joined(separator: "; ")
            }
        }
        write(.error, source: source, category: category, message: message, details: values)
    }

    private static func write(_ level: RuntimeLogEntry.Level, source: String, category: String, message: String, details: [String: String]) {
        RuntimeLogStore.append(RuntimeLogEntry(
            source: source,
            level: level,
            category: category,
            message: message,
            details: details
        ))
    }
}

/// Realtime-location diagnostics keep precise coordinates out of the persisted,
/// exportable log. Exact values are printed only by DEBUG builds for local Xcode
/// debugging.
enum RealtimeLocationTrace {
    static func log(
        _ message: String,
        location: CLLocation,
        details: [String: String] = [:],
        level: RuntimeLogEntry.Level = .info
    ) {
        var metadata = details
        metadata["样本时间"] = ISO8601DateFormatter().string(from: location.timestamp)
        metadata["样本年龄秒"] = format(Date().timeIntervalSince(location.timestamp))
        metadata["水平精度米"] = format(location.horizontalAccuracy)
        metadata["垂直精度米"] = format(location.verticalAccuracy)
        metadata["海拔米"] = format(location.altitude)
        metadata["坐标有效"] = String(CLLocationCoordinate2DIsValid(location.coordinate))
        persist(level, message: message, details: metadata)
        debugCoordinate(message, location: location, details: metadata)
    }

    static func coordinate(
        _ message: String,
        coordinate: CLLocationCoordinate2D,
        details: [String: String] = [:]
    ) {
        #if DEBUG
        let suffix = details.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
        let latitude = String(format: "%.8f", coordinate.latitude)
        let longitude = String(format: "%.8f", coordinate.longitude)
        let metadata = suffix.isEmpty ? "" : "  \(suffix)"
        print("[RealtimeLocation] \(message)  latitude=\(latitude)  longitude=\(longitude)\(metadata)")
        #endif
    }

    private static func persist(
        _ level: RuntimeLogEntry.Level,
        message: String,
        details: [String: String]
    ) {
        switch level {
        case .debug: RuntimeLogger.debug("APP", "实时定位", message, details: details)
        case .info: RuntimeLogger.info("APP", "实时定位", message, details: details)
        case .warning: RuntimeLogger.warning("APP", "实时定位", message, details: details)
        case .error: RuntimeLogger.error("APP", "实时定位", message, details: details)
        }
    }

    private static func debugCoordinate(
        _ message: String,
        location: CLLocation,
        details: [String: String]
    ) {
        coordinate(message, coordinate: location.coordinate, details: details)
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        return String(format: "%.3f", value)
    }
}
