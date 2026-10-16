import SwiftUI
import UIKit

enum EditorFormatCommand {
    case bold
    case italic
    case strikethrough
    case underline
    case code
    case clear
    case bullets
    case numbered
    case insert(String)
}

struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var command: EditorFormatCommand?
    var onFirstEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFirstEdit: onFirstEdit)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = AppStyle.uiInk
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false
        textView.alwaysBounceVertical = false
        textView.allowsEditingTextAttributes = false
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.lineFragmentPadding = 0
        textView.text = text
        textView.typingAttributes = context.coordinator.defaultTypingAttributes
        textView.inputAccessoryView = context.coordinator.makeKeyboardAccessory(for: textView)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
            textView.invalidateIntrinsicContentSize()
        }

        guard let command else { return }
        context.coordinator.isApplyingCommand = true
        context.coordinator.apply(command, to: textView)
        context.coordinator.isApplyingCommand = false
        textView.invalidateIntrinsicContentSize()
        DispatchQueue.main.async {
            self.command = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(260, ceil(size.height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private let onFirstEdit: () -> Void
        private weak var activeTextView: UITextView?
        var isApplyingCommand = false
        private var didTrackFirstEdit = false

        let defaultTypingAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: AppStyle.uiInk
        ]

        init(text: Binding<String>, onFirstEdit: @escaping () -> Void) {
            _text = text
            self.onFirstEdit = onFirstEdit
        }

        func makeKeyboardAccessory(for textView: UITextView) -> UIToolbar {
            activeTextView = textView
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard))
            ]
            return toolbar
        }

        @objc private func dismissKeyboard() {
            activeTextView?.resignFirstResponder()
        }

        func textViewDidChange(_ textView: UITextView) {
            trackFirstEdit()
            textView.invalidateIntrinsicContentSize()
            publish(textView.text)
        }

        func apply(_ command: EditorFormatCommand, to textView: UITextView) {
            switch command {
            case .bold:
                replaceSelection(in: textView) { Self.boldText($0) }
            case .italic:
                replaceSelection(in: textView) { Self.italicText($0) }
            case .strikethrough:
                replaceSelection(in: textView) { Self.combine($0, mark: "\u{0336}") }
            case .underline:
                replaceSelection(in: textView) { Self.combine($0, mark: "\u{0332}") }
            case .code:
                replaceSelection(in: textView) { Self.transform(Self.plainText($0), lowerOffset: 0x1D68A, upperOffset: 0x1D670, digitOffset: 0x1D7F6) }
            case .clear:
                if textView.selectedRange.length == 0 {
                    textView.selectedRange = NSRange(location: 0, length: (textView.text as NSString).length)
                }
                replaceSelection(in: textView) { Self.plainText($0) }
            case .bullets:
                prefixSelectedLines(in: textView) { _ in "• " }
            case .numbered:
                prefixSelectedLines(in: textView) { "\($0 + 1). " }
            case .insert(let value):
                insert(value, in: textView)
            }
        }

        private func insert(_ value: String, in textView: UITextView) {
            let selectedRange = textView.selectedRange
            textView.textStorage.replaceCharacters(in: selectedRange, with: value)
            textView.selectedRange = NSRange(
                location: selectedRange.location + (value as NSString).length,
                length: 0
            )
            trackFirstEdit()
            publish(textView.text)
        }

        private func replaceSelection(in textView: UITextView, transform: (String) -> String) {
            let selectedRange = textView.selectedRange
            guard selectedRange.length > 0 else { return }
            let selectedText = (textView.text as NSString).substring(with: selectedRange)
            let replacement = transform(selectedText)
            textView.textStorage.replaceCharacters(in: selectedRange, with: replacement)
            textView.selectedRange = NSRange(location: selectedRange.location, length: (replacement as NSString).length)
            publish(textView.text)
        }

        private func prefixSelectedLines(in textView: UITextView, prefix: (Int) -> String) {
            replaceSelectedLines(in: textView) { lines in
                lines.enumerated().map { prefix($0.offset) + $0.element }.joined(separator: "\n")
            }
        }

        private func removeSelectedLinePrefix(in textView: UITextView) {
            replaceSelectedLines(in: textView) { lines in
                lines.map { line in
                    if line.hasPrefix("\t") { return String(line.dropFirst()) }
                    if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
                    if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
                    return line.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression)
                }
                .joined(separator: "\n")
            }
        }

        private func replaceSelectedLines(in textView: UITextView, transform: ([String]) -> String) {
            let nsText = textView.text as NSString
            let selectedRange = textView.selectedRange
            let lineRange = nsText.lineRange(for: selectedRange)
            let replacement = transform(nsText.substring(with: lineRange).split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            textView.textStorage.replaceCharacters(in: lineRange, with: replacement)
            textView.selectedRange = NSRange(location: lineRange.location, length: (replacement as NSString).length)
            publish(textView.text)
        }

        private func publish(_ value: String) {
            if isApplyingCommand {
                DispatchQueue.main.async {
                    self.text = value
                }
            } else {
                text = value
            }
        }

        private func trackFirstEdit() {
            guard !didTrackFirstEdit else { return }
            didTrackFirstEdit = true
            onFirstEdit()
        }

        private static func boldText(_ value: String) -> String {
            transform(value, lowerOffset: 0x1D5EE, upperOffset: 0x1D5D4, digitOffset: 0x1D7EC)
        }

        private static func italicText(_ value: String) -> String {
            transform(value, lowerOffset: 0x1D622, upperOffset: 0x1D608, digitOffset: nil)
        }

        private static func transform(_ value: String, lowerOffset: Int, upperOffset: Int, digitOffset: Int?) -> String {
            String(value.unicodeScalars.map { scalar in
                let code = Int(scalar.value)
                if (65...90).contains(code), let mapped = UnicodeScalar(upperOffset + code - 65) {
                    return Character(mapped)
                }
                if (97...122).contains(code), let mapped = UnicodeScalar(lowerOffset + code - 97) {
                    return Character(mapped)
                }
                if let digitOffset, (48...57).contains(code), let mapped = UnicodeScalar(digitOffset + code - 48) {
                    return Character(mapped)
                }
                return Character(scalar)
            })
        }

        private static func combine(_ value: String, mark: Character) -> String {
            value.flatMap { [$0, mark] }.map(String.init).joined()
        }

        private static func plainText(_ value: String) -> String {
            let stripped = value.replacingOccurrences(of: "`", with: "")
            return stripped.decomposedStringWithCanonicalMapping
                .unicodeScalars
                .compactMap { scalar -> String? in
                    if scalar.value == 0x0332 || scalar.value == 0x0336 { return nil }
                    return String(plainScalar(scalar) ?? scalar)
                }
                .joined()
        }

        private static func plainScalar(_ scalar: UnicodeScalar) -> UnicodeScalar? {
            let code = Int(scalar.value)
            switch code {
            // The web editor uses serif mathematical bold/italic characters.
            case 0x1D400...0x1D419:
                return UnicodeScalar(65 + code - 0x1D400)
            case 0x1D41A...0x1D433:
                return UnicodeScalar(97 + code - 0x1D41A)
            case 0x1D7CE...0x1D7D7:
                return UnicodeScalar(48 + code - 0x1D7CE)
            case 0x1D434...0x1D44D:
                return UnicodeScalar(65 + code - 0x1D434)
            case 0x1D44E...0x1D467:
                return UnicodeScalar(97 + code - 0x1D44E)
            case 0x210E:
                return UnicodeScalar(104)
            case 0x1D5D4...0x1D5ED:
                return UnicodeScalar(65 + code - 0x1D5D4)
            case 0x1D5EE...0x1D607:
                return UnicodeScalar(97 + code - 0x1D5EE)
            case 0x1D7EC...0x1D7F5:
                return UnicodeScalar(48 + code - 0x1D7EC)
            case 0x1D608...0x1D621:
                return UnicodeScalar(65 + code - 0x1D608)
            case 0x1D622...0x1D63B:
                return UnicodeScalar(97 + code - 0x1D622)
            case 0x1D670...0x1D689:
                return UnicodeScalar(65 + code - 0x1D670)
            case 0x1D68A...0x1D6A3:
                return UnicodeScalar(97 + code - 0x1D68A)
            case 0x1D7F6...0x1D7FF:
                return UnicodeScalar(48 + code - 0x1D7F6)
            default:
                return nil
            }
        }
    }
}

private final class EditorTextView: UITextView {
    private static let allowedMenuActions: Set<Selector> = [
        #selector(cut(_:)),
        #selector(copy(_:)),
        #selector(paste(_:)),
        #selector(select(_:)),
        #selector(selectAll(_:))
    ]

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard Self.allowedMenuActions.contains(action) else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}
