import AppKit
import SwiftUI

/// Hover is a temporary preview; activating the native button pins the same popover.
struct HoverDetailsButton<Label: View, Content: View>: View {
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var presented = false
    @State private var pinned = false
    @State private var buttonHovered = false
    @State private var contentHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var triggerFocused: Bool

    var body: some View {
        Button {
            hoverTask?.cancel()
            pinned = true
            presented = true
        } label: {
            label()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .focused($triggerFocused)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { inside in
            buttonHovered = inside
            updateHover()
        }
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            content()
                .onHover { inside in
                    contentHovered = inside
                    updateHover()
                }
                .onExitCommand { presented = false }
        }
        .onExitCommand { presented = false }
        .onChange(of: presented) { visible in
            if !visible {
                hoverTask?.cancel()
                pinned = false
                contentHovered = false
                triggerFocused = true
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
            presented = false
            pinned = false
            buttonHovered = false
            contentHovered = false
        }
    }

    private func updateHover() {
        hoverTask?.cancel()
        guard !pinned else { return }
        let inside = buttonHovered || contentHovered
        guard inside != presented else { return }
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
            guard !Task.isCancelled, !pinned,
                  (buttonHovered || contentHovered) == inside else { return }
            presented = inside
        }
    }
}

/// Each details surface grows naturally until its own viewport must scroll.
struct DetailsScrollView<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 1

    private var maximumHeight: CGFloat {
        min(420, max(160, (NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 660) - 100))
    }

    var body: some View {
        ScrollView {
            content()
                .padding(14)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DetailsContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .frame(width: width, height: min(contentHeight, maximumHeight))
        .onPreferenceChange(DetailsContentHeightKey.self) { height in
            if height > 0, abs(contentHeight - height) > 0.5 { contentHeight = height }
        }
    }
}

private struct DetailsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
