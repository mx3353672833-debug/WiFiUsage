import Foundation

/// Canonicalizes Wi-Fi names at every identity and persistence boundary.
public enum WiFiNetworkName {
    private static let placeholderValues: Set<String> = [
        "<redacted>",
        "<unknown>",
        "<none>",
        "(null)",
        "(none)",
        "null"
    ]

    public static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let comparisonValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comparisonValue.isEmpty else { return nil }
        guard !placeholderValues.contains(comparisonValue.lowercased()) else { return nil }
        return comparisonValue
    }
}
