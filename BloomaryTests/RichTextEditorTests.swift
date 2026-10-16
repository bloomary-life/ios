import SwiftUI
import Testing
import UIKit
@testable import Bloomary

@MainActor
struct RichTextEditorTests {
    @Test
    func boldFormatsSelectedTextAsUnicodeBold() {
        #expect(apply(.bold, to: "Heading", selectAll: true) == "𝗛𝗲𝗮𝗱𝗶𝗻𝗴")
    }

    @Test
    func codeProducesLinkedInUnicodeInsteadOfBackticks() {
        #expect(apply(.code, to: "Ab1", selectAll: true) == "𝙰𝚋𝟷")
    }

    @Test
    func clearWithNoSelectionRemovesWebFormattingAndPreservesOtherText() {
        #expect(apply(.clear, to: "𝐀𝐛𝟏 𝑥ℎ — Привет 😀", selectAll: false) == "Ab1 xh — Привет 😀")
    }

    @Test
    func codeConvertsExistingWebBoldAndItalic() {
        #expect(apply(.code, to: "𝐀𝐛𝟏 𝑥ℎ", selectAll: true) == "𝙰𝚋𝟷 𝚡𝚑")
    }

    private func apply(_ command: EditorFormatCommand, to text: String, selectAll: Bool) -> String {
        var boundText = text
        let coordinator = RichTextEditor.Coordinator(text: Binding(get: { boundText }, set: { boundText = $0 }), onFirstEdit: {})
        let view = UITextView()
        view.text = text
        view.selectedRange = NSRange(location: 0, length: selectAll ? (text as NSString).length : 0)
        coordinator.apply(command, to: view)
        #expect(view.text == boundText)
        return boundText
    }
}
