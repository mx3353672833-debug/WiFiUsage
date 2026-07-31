import Foundation
import UsageCore

extension UInt64 {
    var formattedByteCount: String {
        guard self > 0 else { return "0 B" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: self),
            countStyle: .decimal
        )
    }
}

extension UsageBytes {
    var totalDescription: String { totalBytes.formattedByteCount }
    var downloadDescription: String { downloadedBytes.formattedByteCount }
    var uploadDescription: String { uploadedBytes.formattedByteCount }
}

extension Decimal {
    func currencyDescription(code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        return formatter.string(from: self as NSDecimalNumber) ?? "\(code) \(self)"
    }
}

extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
