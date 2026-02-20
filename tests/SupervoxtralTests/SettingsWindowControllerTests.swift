import AppKit
import Testing
@testable import supervoxtral

@Suite("Preferences Window")
@MainActor
struct SettingsWindowControllerTests {
    @Test
    func preferencesWindowContainsTabbedForm() {
        _ = NSApplication.shared

        let controller = SettingsWindowController()
        let contentView = controller.window?.contentView
        #expect(contentView != nil)
        guard let contentView else { return }

        #expect(!contentView.subviews.isEmpty)

        let tabViews = collectViews(of: NSTabView.self, in: contentView)
        #expect(tabViews.count == 1)
        #expect(tabViews.first?.numberOfTabViewItems == 3)

        let labels = collectViews(of: NSTextField.self, in: contentView).map(\.stringValue)
        #expect(labels.contains("Runtime"))

        let prefixTextView = reflectedTextView(named: "transcriptPrefixTextView", in: controller)
        let suffixTextView = reflectedTextView(named: "transcriptSuffixTextView", in: controller)
        #expect(prefixTextView != nil)
        #expect(suffixTextView != nil)
        #expect(prefixTextView?.isEditable == true)
        #expect(prefixTextView?.isSelectable == true)
        #expect(suffixTextView?.isEditable == true)
        #expect(suffixTextView?.isSelectable == true)
    }

    private func collectViews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let cast = root as? T {
            matches.append(cast)
        }
        if let scrollView = root as? NSScrollView, let documentView = scrollView.documentView {
            matches.append(contentsOf: collectViews(of: type, in: documentView))
        }
        for subview in root.subviews {
            matches.append(contentsOf: collectViews(of: type, in: subview))
        }
        return matches
    }

    private func reflectedTextView(named name: String, in controller: SettingsWindowController) -> NSTextView? {
        let mirror = Mirror(reflecting: controller)
        for child in mirror.children where child.label == name {
            return child.value as? NSTextView
        }
        return nil
    }
}
