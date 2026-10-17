import AppKit
import ApplicationServices

/// An application launch is not a handoff. Verify the new composer, attachment,
/// and prompt before reporting readiness. Never submit; preserve any existing draft text.
@MainActor
enum FeedbackHandoff {
    static func open(_ request: FeedbackLaunchRequest, completion: @escaping (FeedbackHandoffResult) -> Void) {
        guard request.conversationEntry != .unsupported, let file = request.file,
              FileManager.default.isReadableFile(atPath: file.path) else {
            completion(.failed)
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            completion(.accessibilityRequired)
            return
        }
        Task {
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                    let finished: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                        if let app { continuation.resume(returning: app) }
                        else { continuation.resume(throwing: error ?? HandoffError.unavailable) }
                    }
                    if request.urls.isEmpty {
                        NSWorkspace.shared.openApplication(at: request.applicationURL, configuration: configuration, completionHandler: finished)
                    } else {
                        NSWorkspace.shared.open(request.urls, withApplicationAt: request.applicationURL,
                                                configuration: configuration, completionHandler: finished)
                    }
                }
                let session = Session(app: app)
                do { try await session.prepare(request) }
                catch {
                    NSLog("Feedback handoff stage: %@", session.stage)
                    throw error
                }
                completion(.ready)
            } catch {
                NSLog("Feedback handoff failed: %@", String(describing: error))
                completion(.failed)
            }
        }
    }

    nonisolated static func containsPrompt(_ text: String, _ prompt: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "\u{200B}", with: "")
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return !prompt.isEmpty && normalized(text).contains(normalized(prompt))
    }

    private enum HandoffError: Error { case unavailable, interrupted, timeout }

    @MainActor private final class Session {
        let app: NSRunningApplication
        let root: AXUIElement
        var stage = "activate"
        init(app: NSRunningApplication) {
            self.app = app
            root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 1)
            // Electron only exposes its web accessibility tree when requested.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        func prepare(_ request: FeedbackLaunchRequest) async throws {
            try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == self.app.processIdentifier }
            stage = "new-conversation"
            switch request.conversationEntry {
            case .folder, .codex, .cursor: break // Their native routes create a new composer.
            default:
                // Use the app's actual New Chat action, never a generic Cmd+N
                // that might create a file/window instead of a conversation.
                let labels = ["New Chat", "New chat", "New Conversation", "New conversation", "New Session", "New session",
                              "新聊天", "新建聊天", "新对话", "新建对话", "新建会话", "新建任务", "新建"]
                try await wait {
                    guard let action = self.elements().first(where: {
                        ["AXButton", "AXMenuItem", "AXLink"].contains(Self.string($0, kAXRoleAttribute)) &&
                        labels.contains(Self.label($0))
                    }) else { return false }
                    return AXUIElementPerformAction(action, kAXPressAction as CFString) == .success
                }
            }
            try await Task.sleep(for: .milliseconds(600))
            stage = "composer"
            let prompt = request.prompt
            var composer: AXUIElement?
            try await wait {
                composer = self.elements().first(where: {
                    guard Self.string($0, kAXRoleAttribute) == "AXTextArea" else { return false }
                    let value = Self.string($0, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}")))
                    if [.codex, .cursor].contains(request.conversationEntry) { return value == prompt }
                    return true
                })
                return composer != nil
            }
            guard let composer, let file = request.file else { throw HandoffError.unavailable }
            try ensureForeground()
            guard AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw HandoffError.unavailable
            }
            try await Task.sleep(for: .milliseconds(200))
            stage = "attach-file"
            let clipboard = ClipboardLease()
            defer { clipboard.restore() }
            // Files and text must be pasted separately: Electron discards text
            // in mixed file/text clipboard events. Chat clients need an actual
            // attachment rather than a local path they cannot access.
            if request.conversationEntry == .antigravity {
                try await attachFileWithPicker(file)
            } else {
                try clipboard.write(file: file)
                try paste()
                if request.conversationEntry == .antigravity {
                    // Its rich-text editor publishes AXValue on blur.
                    try key(48, flags: [])
                    try await Task.sleep(for: .milliseconds(150))
                    try ensureForeground()
                    _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                try await wait {
                    self.elements(excludingComposerContent: true).contains {
                        let label = Self.label($0)
                        let value = Self.string($0, kAXValueAttribute)
                        return Self.string($0, kAXRoleAttribute) != "AXTextArea" &&
                            (label.hasSuffix(file.lastPathComponent) || value == file.lastPathComponent)
                    }
                }
            }
            stage = "prompt"
            if !FeedbackHandoff.containsPrompt(Self.string(composer, kAXValueAttribute), prompt) {
                let currentText = Self.string(composer, kAXValueAttribute)
                try ensureForeground()
                guard AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                    throw HandoffError.unavailable
                }
                var range = CFRange(location: currentText.utf16.count, length: 0)
                if request.conversationEntry == .antigravity {
                    // Rich-text mentions make AX character offsets unreliable.
                    try key(125, flags: .maskCommand)
                } else if let selection = AXValueCreate(.cfRange, &range) {
                    guard AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, selection) == .success else {
                        throw HandoffError.unavailable
                    }
                }
                try clipboard.write(text: (currentText.isEmpty ? "" : "\n") + prompt)
                try paste()
                if request.conversationEntry == .antigravity {
                    // Its rich-text editor publishes AXValue on blur.
                    try key(48, flags: [])
                    try await Task.sleep(for: .milliseconds(150))
                    try ensureForeground()
                    _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                try await wait {
                    self.elements().contains {
                        Self.string($0, kAXRoleAttribute) == "AXTextArea" && FeedbackHandoff.containsPrompt(Self.string($0, kAXValueAttribute), prompt)
                    }
                }
            }
        }

        /// Antigravity imports text attachments through Media, not file paste.
        /// Select only this report; never grant access to another directory.
        func attachFileWithPicker(_ file: URL) async throws {
            stage = "media-menu"
            try await press(labels: ["Add context", "添加上下文"], roles: ["AXPopUpButton"])
            try await press(labels: ["Media", "媒体"], roles: ["AXMenuItem"])
            stage = "file-panel"
            var panel: AXUIElement?
            try await wait {
                panel = self.elements().first {
                    Self.string($0, kAXRoleAttribute) == "AXSheet" &&
                    ["Open", "打开"].contains(Self.label($0))
                }
                return panel != nil
            }
            guard let panel else { throw HandoffError.unavailable }
            var completed = false
            defer {
                if !completed, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                   let cancel = elements(in: panel).first(where: {
                       Self.string($0, kAXRoleAttribute) == "AXButton" && ["Cancel", "取消"].contains(Self.label($0))
                   }) { _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString) }
            }
            // Go to Folder is a standard NSOpenPanel command. Return is sent
            // only while its sheet contains the exact directory we just set.
            stage = "path-sheet"
            try key(5, flags: [.maskCommand, .maskShift])
            var pathField: AXUIElement?
            try await wait {
                guard let sheet = self.elements(in: panel).first(where: { Self.string($0, kAXRoleAttribute) == "AXSheet" && !CFEqual($0, panel) }) else { return false }
                pathField = self.elements(in: sheet).first { Self.string($0, kAXRoleAttribute) == "AXTextField" }
                return pathField != nil
            }
            guard let pathField,
                  AXUIElementSetAttributeValue(pathField, kAXValueAttribute as CFString, file.path as CFString) == .success else {
                throw HandoffError.unavailable
            }
            try await wait { Self.string(pathField, kAXValueAttribute) == file.path }
            stage = "choose-file"
            try key(36, flags: [])
            try await wait {
                let nodes = self.elements(in: panel)
                return !nodes.contains { Self.string($0, kAXRoleAttribute) == "AXSheet" && !CFEqual($0, panel) } &&
                    nodes.contains { Self.string($0, kAXRoleAttribute) == "AXPopUpButton" && Self.string($0, kAXValueAttribute) == file.deletingLastPathComponent().lastPathComponent }
            }
            guard let button = elements(in: panel).first(where: {
                Self.string($0, kAXRoleAttribute) == "AXButton" && ["Open", "打开"].contains(Self.label($0))
            }), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw HandoffError.unavailable
            }
            stage = "attachment"
            try await wait {
                self.elements().contains {
                    Self.string($0, kAXRoleAttribute) == "AXButton" && Self.label($0).hasSuffix(file.lastPathComponent)
                }
            }
            completed = true
        }

        func press(labels: [String], roles: [String]) async throws {
            try await wait {
                guard let node = self.elements().first(where: {
                    roles.contains(Self.string($0, kAXRoleAttribute)) && labels.contains(Self.label($0))
                }) else { return false }
                return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
            }
        }

        func key(_ code: CGKeyCode, flags: CGEventFlags) throws {
            try ensureForeground()
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw HandoffError.unavailable }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        func ensureForeground() throws {
            guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw HandoffError.interrupted
            }
        }

        func paste() throws {
            try ensureForeground()
            guard let item = elements().first(where: {
                Self.string($0, kAXRoleAttribute) == "AXMenuItem" && ["Paste", "粘贴", "贴上"].contains(Self.label($0))
            }), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                throw HandoffError.unavailable
            }
        }

        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<60 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(200))
                try ensureForeground()
            }
            throw HandoffError.timeout
        }

        func elements(in subtree: AXUIElement? = nil, excludingComposerContent: Bool = false) -> [AXUIElement] {
            var result: [AXUIElement] = []
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 40, result.count < 6000 else { return }
                if excludingComposerContent && Self.string(element, kAXRoleAttribute) == "AXTextArea" { return }
                result.append(element)
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
                   let children = ref as? [AXUIElement] {
                    children.forEach { visit($0, depth: depth + 1) }
                }
            }
            visit(subtree ?? root, depth: 0)
            return result
        }

        static func string(_ element: AXUIElement, _ attribute: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return "" }
            return ref as? String ?? ""
        }

        static func label(_ element: AXUIElement) -> String {
            let title = string(element, kAXTitleAttribute)
            return title.isEmpty ? string(element, kAXDescriptionAttribute) : title
        }
    }

    @MainActor final class ClipboardLease {
        let pasteboard: NSPasteboard
        let saved: [[NSPasteboard.PasteboardType: Data]]
        var changeCount: Int
        init(pasteboard: NSPasteboard = .general) {
            self.pasteboard = pasteboard
            saved = pasteboard.pasteboardItems?.map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            } ?? []
            changeCount = pasteboard.changeCount
        }
        func write(file: URL) throws {
            try check()
            pasteboard.clearContents()
            guard pasteboard.writeObjects([file as NSURL]) else { throw HandoffError.unavailable }
            changeCount = pasteboard.changeCount
        }
        func write(text: String) throws {
            try check()
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { throw HandoffError.unavailable }
            changeCount = pasteboard.changeCount
        }
        func check() throws {
            guard pasteboard.changeCount == changeCount else { throw HandoffError.interrupted }
        }
        func restore() {
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            let items = saved.map { data in
                let item = NSPasteboardItem()
                for (type, value) in data { item.setData(value, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }
}
