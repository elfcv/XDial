import AppKit
import SwiftUI

struct FeedbackView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var feedback: FeedbackCoordinator
    @State private var showsPreview = false

    private func text(_ key: String) -> String {
        let code = state.language == .zh ? "zh-Hans" : "en"
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: "feedback." + key, value: nil, table: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text(feedback.context.origin == .general ? "intro"
                : feedback.context.origin == .scenarioSwitchFailure ? "intro.switch" : "intro.connection"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if feedback.context.origin != .general {
                HStack(alignment: .top) {
                    Text(text(!feedback.includeDiagnostics ? "context.omitted"
                        : feedback.context.origin == .scenarioSwitchFailure ? "context.switch" : "context.connection"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(text("context.clear")) { feedback.begin() }
                }
                .font(.system(size: 11))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(text(feedback.context.origin == .general ? "description" : "description.additional")).fontWeight(.medium)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $feedback.description)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .accessibilityLabel(text("description"))
                    if feedback.description.isEmpty {
                        Text(text(feedback.context.origin == .general ? "placeholder." + feedback.kind.rawValue : "placeholder.additional"))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 110)
                .background(XDialPalette.elevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)))
                .onChange(of: feedback.description) {
                    if feedback.description.count > FeedbackPackage.descriptionLimit {
                        feedback.description = String(feedback.description.prefix(FeedbackPackage.descriptionLimit))
                    }
                }
            }
            Toggle(text("includeDiagnostics"), isOn: $feedback.includeDiagnostics)
                .toggleStyle(.switch)
            DisclosureGroup(text("preview"), isExpanded: $showsPreview) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("privacy"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsPreview {
                        SettingsReadOnlyText(text: (try? feedback.package().text(english: state.language == .en)) ?? "", multiline: true)
                            .frame(height: 160)
                    }
                }
                .padding(.top, 6)
            }
            Divider()
            assistantSection
            if let outcome = feedback.outcome {
                Label(outcomeText(outcome), systemImage: isError(outcome) ? "exclamationmark.circle" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isError(outcome) ? XDialPalette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feedback.outcome")
            }
            if feedback.fileURL != nil {
                Button(text("reveal")) { feedback.revealFile() }
                    .buttonStyle(.link)
            }
        }
        .onAppear { refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            feedback.refreshAssistants()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            feedback.refreshAssistants()
        }
    }

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(text("assistant")).fontWeight(.medium)
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help(text("refresh"))
                    .accessibilityLabel(text("refresh"))
            }
            if feedback.assistants.isEmpty {
                Text(text("noAssistant"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(text("download")) { feedback.downloadCindy() }
                    .buttonStyle(.borderedProminent)
            } else {
                if feedback.selectedAssistant == nil {
                    ForEach(feedback.assistants) { assistant in
                        Button(String(format: text("choose"), assistant.name)) {
                            feedback.selectedAssistantID = assistant.id
                        }
                    }
                } else if feedback.assistants.count > 1 {
                    Picker(text("assistant"), selection: $feedback.selectedAssistantID) {
                        ForEach(feedback.assistants) { assistant in
                            Text(assistant.name).tag(assistant.id)
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let assistant = feedback.selectedAssistant {
                    Button {
                        feedback.continueInAssistant(english: state.language == .en)
                    } label: {
                        HStack(spacing: 7) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: assistant.applicationURL.path))
                                .resizable().frame(width: 18, height: 18)
                            Text(String(format: text(assistant.supportsNewConversation ? "newConversation" : "continue"), assistant.name))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(feedback.isOpening)
                }
                Text(text(feedback.selectedAssistant?.conversationEntry == .codex ? "codexHint"
                    : feedback.selectedAssistant?.conversationEntry == .folder ? "folderHint" : "handoffHint"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        feedback.refreshAssistants()
        state.refreshFeedbackSnapshot()
    }

    private func outcomeText(_ outcome: FeedbackCoordinator.Outcome) -> String {
        switch outcome {
        case .copied: return text("copied")
        case .opened(let name): return String(format: text("opened"), name)
        case .conversationRequested(let name, let entry):
            return String(format: text(entry == .codex ? "codexRequested" : "folderRequested"), name)
        case .assistantUnavailable: return text("assistantUnavailable")
        case .openFailed: return text("openFailed")
        case .exportFailed: return text("exportFailed")
        case .downloadFailed: return text("downloadFailed")
        }
    }

    private func isError(_ outcome: FeedbackCoordinator.Outcome) -> Bool {
        switch outcome {
        case .assistantUnavailable, .openFailed, .exportFailed, .downloadFailed: return true
        default: return false
        }
    }
}
