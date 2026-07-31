import Foundation

/// One per-process observation produced by macOS `nettop`.
///
/// The values are cumulative in regular logging mode and interval deltas when
/// `nettop` is launched with `-d`.
public struct ProcessNetworkCounter: Equatable, Sendable {
    public let processName: String
    public let processIdentifier: Int32
    public let processStartedAt: Date?
    public let bytes: UsageBytes

    public init(
        processName: String,
        processIdentifier: Int32,
        processStartedAt: Date? = nil,
        bytes: UsageBytes
    ) {
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.processStartedAt = processStartedAt
        self.bytes = bytes
    }

    fileprivate var key: ProcessNetworkKey {
        ProcessNetworkKey(
            name: processName,
            identifier: processIdentifier,
            startedAt: processStartedAt
        )
    }
}

/// A normalized interval delta derived from two cumulative `nettop` snapshots.
public struct ProcessNetworkDelta: Equatable, Sendable {
    public let processName: String
    public let processIdentifier: Int32
    public let startedAt: Date
    public let endedAt: Date
    public let bytes: UsageBytes

    public init(
        processName: String,
        processIdentifier: Int32,
        startedAt: Date,
        endedAt: Date,
        bytes: UsageBytes
    ) {
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bytes = bytes
    }
}

private struct ProcessNetworkKey: Hashable, Sendable {
    let name: String
    let identifier: Int32
    let startedAt: Date?
}

/// Parses the stable subset of CSV emitted by macOS `nettop`.
///
/// Column positions are discovered from each repeated header so the parser
/// remains valid if macOS changes the order requested through `-J`.
public enum ProcessNetworkSnapshotParser {
    public static func parse(_ output: String) -> [ProcessNetworkCounter] {
        parseFrames(output).last ?? []
    }

    /// Returns every complete logging frame in order. `nettop` repeats the CSV
    /// header before each frame when more than one sample is requested.
    public static func parseFrames(_ output: String) -> [[ProcessNetworkCounter]] {
        var frames: [[ProcessNetworkCounter]] = []
        var currentFrame: [ProcessNetworkCounter]?
        var layout: ColumnLayout?

        for rawLine in output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let fields = parseCSVLine(String(rawLine)) else { continue }
            if let headerLayout = ColumnLayout(header: fields) {
                if let currentFrame {
                    frames.append(currentFrame)
                }
                currentFrame = []
                layout = headerLayout
                continue
            }

            guard let layout, let counter = parseRecord(fields, layout: layout) else {
                continue
            }
            currentFrame?.append(counter)
        }

        if let currentFrame {
            frames.append(currentFrame)
        }
        return frames
    }

    private struct ColumnLayout {
        let identity: Int
        let inbound: Int
        let outbound: Int

        init?(header: [String]) {
            guard header.first?.isEmpty == true,
                  let inbound = header.firstIndex(of: "bytes_in"),
                  let outbound = header.firstIndex(of: "bytes_out") else {
                return nil
            }
            identity = 0
            self.inbound = inbound
            self.outbound = outbound
        }
    }

    private static func parseRecord(
        _ fields: [String],
        layout: ColumnLayout
    ) -> ProcessNetworkCounter? {
        let maximumIndex = max(layout.identity, layout.inbound, layout.outbound)
        guard fields.indices.contains(maximumIndex) else { return nil }

        let identity = fields[layout.identity]
        guard let inbound = UInt64(fields[layout.inbound]),
              let outbound = UInt64(fields[layout.outbound]),
              let processSeparator = identity.lastIndex(of: "."),
              let processIdentifier = Int32(identity[identity.index(after: processSeparator)...]) else {
            return nil
        }

        let processName = String(identity[..<processSeparator])
        guard !processName.isEmpty, processIdentifier > 0 else { return nil }

        return ProcessNetworkCounter(
            processName: processName,
            processIdentifier: processIdentifier,
            bytes: UsageBytes(downloadedBytes: inbound, uploadedBytes: outbound)
        )
    }

    private static func parseCSVLine(_ line: String) -> [String]? {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if isQuoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = line.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            } else if character != "\r" {
                field.append(character)
            }
            index = line.index(after: index)
        }

        guard !isQuoted else { return nil }
        fields.append(field)
        return fields
    }
}

/// Converts periodic cumulative snapshots into conservative deltas.
///
/// Processes already running when collection begins only establish a baseline.
/// A process whose start time proves it launched after the preceding snapshot
/// can safely contribute its complete first counter. Brief disappearances keep
/// their baseline, while counter decreases emit zero rather than a false charge.
public struct ProcessNetworkDeltaTracker: Sendable {
    private struct Baseline: Sendable {
        let bytes: UsageBytes
        let observedAt: Date
    }

    private var previousCounters: [ProcessNetworkKey: Baseline] = [:]
    private var previousObservationDate: Date?
    private let missingProcessRetention: TimeInterval

    public init(missingProcessRetention: TimeInterval = 60) {
        self.missingProcessRetention = max(0, missingProcessRetention)
    }

    public mutating func observe(
        _ counters: [ProcessNetworkCounter],
        at observedAt: Date
    ) -> [ProcessNetworkDelta] {
        guard previousObservationDate == nil || observedAt > previousObservationDate! else {
            return []
        }

        let previousObservationDate = self.previousObservationDate
        let expirationDate = observedAt.addingTimeInterval(-missingProcessRetention)
        previousCounters = previousCounters.filter { $0.value.observedAt >= expirationDate }

        var deltas: [ProcessNetworkDelta] = []
        var observedKeys: Set<ProcessNetworkKey> = []
        for counter in counters where observedKeys.insert(counter.key).inserted {
            defer {
                previousCounters[counter.key] = Baseline(
                    bytes: counter.bytes,
                    observedAt: observedAt
                )
            }

            if let previous = previousCounters[counter.key] {
                let bytes = UsageBytes(
                    downloadedBytes: conservativeDelta(
                        current: counter.bytes.downloadedBytes,
                        previous: previous.bytes.downloadedBytes
                    ),
                    uploadedBytes: conservativeDelta(
                        current: counter.bytes.uploadedBytes,
                        previous: previous.bytes.uploadedBytes
                    )
                )
                guard bytes != .zero else { continue }
                deltas.append(ProcessNetworkDelta(
                    processName: counter.processName,
                    processIdentifier: counter.processIdentifier,
                    startedAt: previous.observedAt,
                    endedAt: observedAt,
                    bytes: bytes
                ))
                continue
            }

            guard let previousObservationDate,
                  let processStartedAt = counter.processStartedAt,
                  processStartedAt >= previousObservationDate,
                  processStartedAt <= observedAt,
                  counter.bytes != .zero else {
                continue
            }
            deltas.append(ProcessNetworkDelta(
                processName: counter.processName,
                processIdentifier: counter.processIdentifier,
                startedAt: processStartedAt,
                endedAt: observedAt,
                bytes: counter.bytes
            ))
        }

        self.previousObservationDate = observedAt
        return deltas
    }

    public mutating func reset() {
        previousCounters.removeAll(keepingCapacity: true)
        previousObservationDate = nil
    }

    private func conservativeDelta(current: UInt64, previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}
