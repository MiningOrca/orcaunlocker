import AppKit
import SwiftUI

extension View {
    func nativeHelp(_ text: String) -> some View {
        overlay {
            NativeToolTip(text: text)
        }
    }
}

private struct NativeToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughToolTipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

private final class PassthroughToolTipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
