import AppKit
import SwiftUI

struct DiagnosticFeedbackCard: View {
    @Environment(AppModel.self) private var model
    @Binding var isFeedbackPresented: Bool
    @State private var isClearing = false
    @State private var showsClearConfirmation = false

    var body: some View {
        GraphiteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("诊断与反馈").font(.headline)
                    Spacer()
                    Label("日志仅存本机", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.usageDownload)
                }

                HStack(spacing: 10) {
                    signalNode(symbol: "doc.text.magnifyingglass", title: "记录问题")
                    signalArrow
                    signalNode(symbol: "hand.raised.fill", title: "由你确认")
                    signalArrow
                    signalNode(symbol: "envelope.fill", title: "发送反馈")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("本地记录问题，由你确认后发送反馈")

                Text("软件会保留最近 7 天的脱敏诊断事件，最多占用 5 MB。只有你明确选择附带日志并点击发送时，日志才会通过 HTTPS 提交至 xjp.one，再转发到反馈邮箱。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("反馈问题") { isFeedbackPresented = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.usageDownload)
                    Button("打开日志位置") { model.revealDiagnosticLogs() }
                    Button("清除本地日志") { showsClearConfirmation = true }
                        .disabled(isClearing)
                }
            }
        }
        .confirmationDialog(
            "清除本地诊断日志？",
            isPresented: $showsClearConfirmation
        ) {
            Button("清除日志", role: .destructive) {
                isClearing = true
                Task {
                    await model.clearDiagnosticLogs()
                    isClearing = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除诊断日志，不会删除流量、Wi-Fi、套餐或应用用量数据。")
        }
    }

    private func signalNode(symbol: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.usageDownload)
                .frame(width: 30, height: 30)
                .background(Color.usageDownload.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var signalArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

struct FeedbackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var reportID = UUID()
    @State private var type: FeedbackType = .other
    @State private var message = ""
    @State private var wantsReply = false
    @State private var contact = ""
    @State private var includeDiagnostics = false
    @State private var diagnosticAttachment: FeedbackDiagnosticAttachment?
    @State private var isPreparingDiagnostics = false
    @State private var isSending = false
    @State private var status: SubmissionStatus?
    @State private var isPreviewExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("反馈问题")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("不用凑字数，把遇到的情况直接告诉我。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)

            Divider().overlay(Color.usageBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(
                        "发送时会附上软件版本、macOS 版本和芯片类型，方便定位兼容性问题；不会发送设备名称或序列号。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    fieldTitle("问题类型")
                    Picker("问题类型", selection: $type) {
                        ForEach(FeedbackType.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            fieldTitle("遇到了什么问题？")
                            Spacer()
                            Text("\(message.count) / 2000")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        ZStack(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("例如：切换 Wi-Fi 后，套餐没有跟着切换。")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $message)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 112)
                                .padding(3)
                        }
                        .background(Color.usageCardRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.usageBorder, lineWidth: 1)
                        }
                        .onChange(of: message) { _, newValue in
                            if newValue.count > 2000 {
                                message = String(newValue.prefix(2000))
                            }
                            status = nil
                        }
                    }

                    GraphiteCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("附带脱敏诊断日志", isOn: $includeDiagnostics)
                                .font(.headline)
                                .onChange(of: includeDiagnostics) { _, enabled in
                                    status = nil
                                    if enabled {
                                        prepareDiagnosticsIfNeeded()
                                    } else {
                                        diagnosticAttachment = nil
                                        isPreviewExpanded = false
                                    }
                                }
                            Text("勾选后会另外附带功能状态和错误代码；不包含 Wi-Fi 名称、应用名称、文件路径、流量记录、套餐内容或联系方式。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if includeDiagnostics {
                                if isPreparingDiagnostics {
                                    Label("正在准备脱敏日志…", systemImage: "clock.arrow.circlepath")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let diagnosticAttachment {
                                    DisclosureGroup("查看将发送的内容", isExpanded: $isPreviewExpanded) {
                                        ScrollView([.horizontal, .vertical]) {
                                            Text(diagnosticAttachment.content)
                                                .font(.system(size: 11, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(10)
                                        }
                                        .frame(height: 150)
                                        .background(Color.black.opacity(0.26))
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }

                    GraphiteCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("希望收到回复", isOn: $wantsReply)
                                .font(.headline)
                                .onChange(of: wantsReply) { _, enabled in
                                    if !enabled { contact = "" }
                                    status = nil
                                }
                            if wantsReply {
                                TextField("邮箱、GitHub 用户名或其他联系方式", text: $contact)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: contact) { _, newValue in
                                        if newValue.count > 160 {
                                            contact = String(newValue.prefix(160))
                                        }
                                        status = nil
                                    }
                            }
                            Text("联系方式与诊断日志是两个独立选项。发送后，内容只用于处理本次问题。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let status {
                        Label(status.message, systemImage: status.symbol)
                            .font(.callout)
                            .foregroundStyle(status.color)
                            .textSelection(.enabled)
                    }
                }
                .padding(22)
            }

            Divider().overlay(Color.usageBorder)

            HStack {
                if status?.isSuccess == true {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { dismiss() }
                    Spacer()
                    Button(isSending ? "正在发送…" : "发送反馈") {
                        sendFeedback()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.usageDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 620, minHeight: 700)
        .background(Color.usageBackground)
    }

    private var canSend: Bool {
        !isSending
            && !isPreparingDiagnostics
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!wantsReply || contact.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3)
            && (!includeDiagnostics || diagnosticAttachment != nil)
    }

    private func fieldTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func prepareDiagnosticsIfNeeded() {
        guard diagnosticAttachment == nil, !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        Task {
            diagnosticAttachment = await model.prepareFeedbackDiagnostics()
            isPreparingDiagnostics = false
        }
    }

    private func sendFeedback() {
        guard canSend else { return }
        isSending = true
        status = nil
        let attachment = includeDiagnostics ? diagnosticAttachment : nil

        Task {
            do {
                let receipt = try await model.submitFeedback(
                    reportID: reportID,
                    type: type,
                    message: message,
                    wantsReply: wantsReply,
                    contact: contact,
                    diagnostics: attachment
                )
                let suffix = receipt.feedbackID.map { "（编号：\($0)）" } ?? ""
                status = SubmissionStatus(
                    message: "反馈已发送\(suffix)。谢谢你把问题告诉我。",
                    symbol: "checkmark.circle.fill",
                    color: Color.usageDownload,
                    isSuccess: true
                )
            } catch {
                status = SubmissionStatus(
                    message: error.localizedDescription,
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange,
                    isSuccess: false
                )
            }
            isSending = false
        }
    }

    private struct SubmissionStatus {
        let message: String
        let symbol: String
        let color: Color
        let isSuccess: Bool
    }
}
