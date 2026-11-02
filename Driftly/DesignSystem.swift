import AppKit
import SwiftUI

/// Driftly uses stock macOS controls throughout; this file only holds the few
/// layout helpers that System Settings itself uses (icon tiles, fitted forms).
enum Metrics {
    static let width: CGFloat = 340
    /// Where a grouped Form's row content starts (20pt section inset + 10pt row padding).
    /// Everything outside the form (header, footer) aligns to this.
    static let contentInset: CGFloat = 30
    /// Grouped forms add ~22.5pt above the first section and ~23pt below the last; these
    /// trim both to exactly 20pt so top, bottom and side insets match.
    static let formTop: CGFloat = -2.5
    static let formBottom: CGFloat = -3
    /// Tallest the panel gets before scrolling: fits a 13" MacBook Air under the menu bar.
    static var maxFormHeight: CGFloat {
        min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
    }
}

/// System Settings–style icon: white SF Symbol on a tinted rounded square.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

/// Disclosure row label: icon tile, title, one-line summary.
struct SectionLabel: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            IconTile(symbol: symbol, tint: tint)
        }
    }
}

/// A grouped Form (the System Settings look) that sizes itself to its content,
/// so the menu-bar panel never shows empty space or scrolls needlessly.
struct FittedForm<Content: View>: View {
    var topEdge: CGFloat = Metrics.formTop
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 420

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, topEdge, for: .scrollContent)
            .contentMargins(.bottom, Metrics.formBottom, for: .scrollContent)
            .modifier(FitToContent(height: $height))
            .frame(height: min(max(height, 120), Metrics.maxFormHeight))
    }
}

/// Tracks the form's content height on macOS 15+; keeps a fixed height on 14.
struct FitToContent: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom }) { _, new in
                    withAnimation(.snappy(duration: 0.25)) { height = new }
                }
        } else {
            content
        }
    }
}

/// Borderless icon button with a full 28pt hit target and a spoken label (HIG minimums).
struct FooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.large)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20)
        }
    }
}
