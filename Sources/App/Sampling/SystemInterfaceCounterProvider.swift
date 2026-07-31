import Foundation
import SystemBridge

public struct SystemInterfaceCounter: Hashable, Sendable {
    public let name: String
    public let index: UInt32
    public let receivedBytes: UInt64
    public let transmittedBytes: UInt64

    public init(name: String, index: UInt32, receivedBytes: UInt64, transmittedBytes: UInt64) {
        self.name = name
        self.index = index
        self.receivedBytes = receivedBytes
        self.transmittedBytes = transmittedBytes
    }
}

public protocol InterfaceCounterProviding: Sendable {
    func interfaceCounters() throws -> [SystemInterfaceCounter]
}

public enum SystemInterfaceCounterError: Error, Equatable, Sendable {
    case systemCall(Int32)
    case unstableSnapshot
}

public struct SystemInterfaceCounterProvider: InterfaceCounterProviding {
    public init() {}

    public func interfaceCounters() throws -> [SystemInterfaceCounter] {
        for _ in 0..<3 {
            var required = 0
            let sizingResult = WUCopyInterfaceCounters(nil, 0, &required)
            guard sizingResult == 0 else {
                throw SystemInterfaceCounterError.systemCall(Int32(sizingResult))
            }
            guard required > 0 else { return [] }

            var counters = Array(repeating: WUInterfaceCounter(), count: required)
            var actual = 0
            let result = counters.withUnsafeMutableBufferPointer { buffer in
                WUCopyInterfaceCounters(buffer.baseAddress, buffer.count, &actual)
            }
            guard result == 0 else {
                throw SystemInterfaceCounterError.systemCall(Int32(result))
            }
            guard actual <= counters.count else { continue }

            return counters.prefix(actual).map { counter in
                var mutableCounter = counter
                let name = withUnsafePointer(to: &mutableCounter.name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) {
                        String(cString: $0)
                    }
                }
                return SystemInterfaceCounter(
                    name: name,
                    index: counter.index,
                    receivedBytes: counter.ibytes,
                    transmittedBytes: counter.obytes
                )
            }
        }
        throw SystemInterfaceCounterError.unstableSnapshot
    }
}
