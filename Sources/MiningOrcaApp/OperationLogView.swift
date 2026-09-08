import AppKit
import Foundation
import MiningOrcaLauncherCore
import SwiftUI

struct OperationLogView: View {
    let appID: UInt32?
    let entries: [LauncherLogEntry]
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppText.GameDetail.recentOperationLog)
                    .font(.headline)
                Spacer()
                Button(AppText.GameDetail.clearOperationLog, action: onClear)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            OperationLogTextView(appID: appID, entries: entries)
                // Five 11.5 pt monospace lines plus the NSTextView vertical insets.
                .frame(minHeight: 92)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.quaternary)
        }
    }
}

private struct OperationLogTextView: NSViewRepresentable {
    let appID: UInt32?
    let entries: [LauncherLogEntry]

    final class Coordinator {
        var appID: UInt32?
        var renderedCount = 0
        var showingPlaceholder = false
        var hasRendered = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = .black

        let contentSize = scrollView.contentSize
        let textView = NSTextView(
            frame: NSRect(origin: .zero, size: contentSize)
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindPanel = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .black
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = true
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let coordinator = context.coordinator
        let gameChanged = coordinator.appID != appID
        let previousOrigin = scrollView.contentView.bounds.origin
        let previousSelection = textView.selectedRange()
        let userHasSelection = previousSelection.length > 0
        let shouldFollowTail = !userHasSelection && (
            gameChanged
                || !coordinator.hasRendered
                || entries.isEmpty
                || isNearBottom(scrollView: scrollView, textView: textView)
        )

        if gameChanged || !coordinator.hasRendered || entries.count < coordinator.renderedCount {
            replaceContents(in: textView)
        } else if coordinator.showingPlaceholder && !entries.isEmpty {
            replaceContents(in: textView)
        } else if entries.count > coordinator.renderedCount {
            appendNewEntries(to: textView, startingAt: coordinator.renderedCount)
        } else if entries.isEmpty && !coordinator.showingPlaceholder {
            replaceContents(in: textView)
        }

        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }

        coordinator.appID = appID
        coordinator.renderedCount = entries.count
        coordinator.showingPlaceholder = entries.isEmpty
        coordinator.hasRendered = true

        if shouldFollowTail {
            if gameChanged {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            scrollToBottom(
                scrollView: scrollView,
                textView: textView
            )
        } else {
            restoreSelection(previousSelection, in: textView)
            scrollView.contentView.scroll(to: previousOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func replaceContents(in textView: NSTextView) {
        if entries.isEmpty {
            textView.textStorage?.setAttributedString(placeholder())
        } else {
            textView.textStorage?.setAttributedString(renderedEntries(entries[...]))
        }
    }

    private func appendNewEntries(to textView: NSTextView, startingAt startIndex: Int) {
        guard startIndex < entries.count else { return }
        let output = NSMutableAttributedString(string: "")
        if startIndex > 0 {
            output.append(NSAttributedString(string: "\n", attributes: messageAttributes))
        }
        output.append(renderedEntries(entries[startIndex...]))
        textView.textStorage?.append(output)
    }

    private func isNearBottom(scrollView: NSScrollView, textView: NSTextView) -> Bool {
        let visible = scrollView.documentVisibleRect
        let documentHeight = textView.bounds.height
        if documentHeight <= visible.height + 1 {
            return true
        }
        return visible.maxY >= documentHeight - 24
    }

    private func scrollToBottom(
        scrollView: NSScrollView,
        textView: NSTextView
    ) {
        // scrollRangeToVisible asks AppKit for the laid-out end-of-document rect,
        // which is more reliable than deriving the tail from the NSTextView frame
        // while SwiftUI is still sizing a newly opened log view.
        let end = textView.string.utf16.count
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restoreSelection(_ range: NSRange, in textView: NSTextView) {
        let length = textView.string.utf16.count
        guard range.location <= length else {
            textView.setSelectedRange(NSRange(location: length, length: 0))
            return
        }
        let available = length - range.location
        textView.setSelectedRange(
            NSRange(location: range.location, length: min(range.length, available))
        )
    }

    private func placeholder() -> NSAttributedString {
        NSAttributedString(
            string: AppText.GameDetail.noOperationLogEntries,
            attributes: secondaryAttributes
        )
    }

    private func renderedEntries(_ slice: ArraySlice<LauncherLogEntry>) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for (offset, entry) in slice.enumerated() {
            if offset > 0 {
                output.append(NSAttributedString(string: "\n", attributes: messageAttributes))
            }
            output.append(renderedEntry(entry))
        }
        return output
    }

    private func renderedEntry(_ entry: LauncherLogEntry) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        output.append(
            NSAttributedString(
                string: "\(time(entry.timestamp))  ",
                attributes: secondaryAttributes
            )
        )
        output.append(
            NSAttributedString(
                string: paddedLevel(entry.levelText),
                attributes: [
                    .font: logFont,
                    .foregroundColor: levelColor(entry.levelText),
                ]
            )
        )
        output.append(
            NSAttributedString(
                string: "  \(entry.message)",
                attributes: messageAttributes
            )
        )
        return output
    }

    private var logFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    }

    private var messageAttributes: [NSAttributedString.Key: Any] {
        [
            .font: logFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
    }

    private var secondaryAttributes: [NSAttributedString.Key: Any] {
        [
            .font: logFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.50),
        ]
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func paddedLevel(_ level: String) -> String {
        level.padding(toLength: 8, withPad: " ", startingAt: 0)
    }

    private func levelColor(_ level: String) -> NSColor {
        switch level {
        case "ERROR", "CRITICAL": return .systemRed
        case "WARNING": return .systemOrange
        case "INFO", "NOTICE": return .systemGreen
        default: return NSColor.white.withAlphaComponent(0.60)
        }
    }
}
