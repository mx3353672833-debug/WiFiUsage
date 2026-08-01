import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isPreparingToTerminate = false

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { [weak self] in
            await self?.model?.refreshWiFiStatus()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate, let model else {
            return isPreparingToTerminate ? .terminateLater : .terminateNow
        }

        isPreparingToTerminate = true
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
