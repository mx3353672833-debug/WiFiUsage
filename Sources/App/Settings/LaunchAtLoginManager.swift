import AppKit
import Foundation

public enum LaunchAtLoginState: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

public protocol LaunchAtLoginManaging: Sendable {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

public enum LaunchAtLoginError: LocalizedError {
    case unstableApplicationLocation
    case invalidBundleIdentifier
    case invalidPropertyList

    public var errorDescription: String? {
        switch self {
        case .unstableApplicationLocation:
            "请先把 WiFiUsage 放进“应用程序”文件夹，再开启登录时启动。"
        case .invalidBundleIdentifier:
            "应用标识无效，无法配置登录时启动。"
        case .invalidPropertyList:
            "无法创建登录启动配置。"
        }
    }
}

/// Entitlement-free login startup backed by a per-user LaunchAgent.
///
/// `SMAppService.mainApp` rejects ad-hoc signed builds on some macOS releases.
/// A user LaunchAgent provides the same next-login behavior without requiring
/// an Apple Developer Program membership or administrator privileges.
public struct LaunchAtLoginManager: LaunchAtLoginManaging, Sendable {
    public let label: String
    private let applicationURL: URL
    private let hasValidBundleIdentifier: Bool

    public init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        hasValidBundleIdentifier = identifier.map(Self.isValidBundleIdentifier) ?? false
        label = hasValidBundleIdentifier ? "\(identifier!).launchAtLogin" : ""
        self.applicationURL = applicationURL.standardizedFileURL
    }

    public var state: LaunchAtLoginState {
        guard hasValidBundleIdentifier, isInStableApplicationsFolder else { return .notFound }
        guard let data = try? Data(contentsOf: launchAgentURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              propertyList["Label"] as? String == label,
              let arguments = propertyList["ProgramArguments"] as? [String],
              arguments.last == applicationURL.path else {
            return .notRegistered
        }
        return .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard hasValidBundleIdentifier else {
            throw LaunchAtLoginError.invalidBundleIdentifier
        }
        if enabled {
            guard isInStableApplicationsFolder else {
                throw LaunchAtLoginError.unstableApplicationLocation
            }
            try FileManager.default.createDirectory(
                at: launchAgentsDirectory,
                withIntermediateDirectories: true
            )
            guard PropertyListSerialization.propertyList(
                launchAgentPropertyList,
                isValidFor: .xml
            ) else {
                throw LaunchAtLoginError.invalidPropertyList
            }
            let data = try PropertyListSerialization.data(
                fromPropertyList: launchAgentPropertyList,
                format: .xml,
                options: 0
            )
            try data.write(to: launchAgentURL, options: .atomic)
            reloadLaunchAgent()
        } else {
            unloadLaunchAgent()
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
        }
    }

    public func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              !identifier.hasPrefix("."),
              !identifier.hasSuffix(".") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
            && identifier.split(separator: ".").allSatisfy { !$0.isEmpty }
    }

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var launchAgentURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    private var isInStableApplicationsFolder: Bool {
        let applicationPath = applicationURL.path
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        return applicationPath.hasPrefix(systemApplications)
            || applicationPath.hasPrefix(userApplications)
    }

    private var launchAgentPropertyList: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                "-gj",
                applicationURL.path
            ],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": ["Aqua"]
        ]
    }

    private func reloadLaunchAgent() {
        unloadLaunchAgent()
        _ = runLaunchctl([
            "bootstrap",
            launchDomain,
            launchAgentURL.path
        ])
    }

    private func unloadLaunchAgent() {
        _ = runLaunchctl([
            "bootout",
            "\(launchDomain)/\(label)"
        ])
    }

    private var launchDomain: String {
        "gui/\(getuid())"
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
