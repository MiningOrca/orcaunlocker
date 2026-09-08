import AppKit
import SwiftUI

private final class RawConfigurationLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentViewBoundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidateLineNumbers() {
        updateRuleThickness()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let source = textView.string as NSString
        let totalLength = source.length

        var characterIndex: Int
        if glyphRange.location < layoutManager.numberOfGlyphs {
            characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        } else {
            characterIndex = totalLength
        }

        let prefixRange = NSRange(location: 0, length: min(characterIndex, totalLength))
        let prefix = prefixRange.length > 0 ? source.substring(with: prefixRange) : ""
        var lineNumber = 1 + prefix.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }

        characterIndex = source.lineRange(for: NSRange(location: min(characterIndex, totalLength), length: 0)).location

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        while characterIndex <= totalLength {
            let lineRange = source.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphRangeForLine = layoutManager.glyphRange(
                forCharacterRange: lineRange,
                actualCharacterRange: nil
            )

            var lineRect: NSRect
            if glyphRangeForLine.length > 0 {
                lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRangeForLine.location,
                    effectiveRange: nil
                )
            } else {
                let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: 12))
                lineRect = NSRect(x: 0, y: 0, width: 0, height: lineHeight)
            }

            let textPoint = NSPoint(
                x: 0,
                y: textView.textContainerOrigin.y + lineRect.minY
            )
            let rulerPoint = convert(textPoint, from: textView)
            let number = String(lineNumber) as NSString
            let numberSize = number.size(withAttributes: attributes)
            number.draw(
                at: NSPoint(
                    x: ruleThickness - numberSize.width - 9,
                    y: rulerPoint.y + max(0, (lineRect.height - numberSize.height) / 2)
                ),
                withAttributes: attributes
            )

            if lineRange.location + lineRange.length >= totalLength {
                break
            }
            characterIndex = lineRange.location + lineRange.length
            lineNumber += 1

            if rulerPoint.y > rect.maxY + lineRect.height {
                break
            }
        }
    }

    private func updateRuleThickness() {
        guard let textView else { return }
        let lineCount = max(1, textView.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        let digits = String(lineCount).count
        ruleThickness = max(44, CGFloat(digits * 8 + 20))
    }
}

struct RawConfigurationEditor: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            (textView.enclosingScrollView?.verticalRulerView as? RawConfigurationLineNumberRulerView)?
                .invalidateLineNumbers()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        // The document may be wider than the viewport, but the editor itself must
        // never contribute that width to SwiftUI layout. NSScrollView owns the
        // viewport and clips the horizontally resizable NSTextView.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = false
        }

        textView.string = text
        scrollView.documentView = textView

        let lineNumberRuler = RawConfigurationLineNumberRulerView(
            textView: textView,
            scrollView: scrollView
        )
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        lineNumberRuler.invalidateLineNumbers()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }

        let selection = textView.selectedRange()
        let visibleOrigin = scrollView.contentView.bounds.origin
        textView.string = text
        (scrollView.verticalRulerView as? RawConfigurationLineNumberRulerView)?
            .invalidateLineNumbers()

        let length = textView.string.utf16.count
        let location = min(selection.location, length)
        let selectedLength = min(selection.length, length - location)
        textView.setSelectedRange(NSRange(location: location, length: selectedLength))
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
