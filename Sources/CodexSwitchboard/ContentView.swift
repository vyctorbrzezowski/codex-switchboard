import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: UsageViewModel

    static func preferredWidth(for mode: AccountInformationMode) -> CGFloat {
        mode == .complete ? 760 : 580
    }

    static func preferredHeight(for mode: AccountInformationMode) -> CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let compactHeight = floor(visibleHeight * 0.92)
        let completeHeight = min(720, floor(visibleHeight * 0.85))
        return mode == .complete ? completeHeight : compactHeight
    }

    static func listMaxHeight(for mode: AccountInformationMode) -> CGFloat {
        max(280, preferredHeight(for: mode) - 84)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(vm: viewModel)
            thinDivider

            if viewModel.isLoading && viewModel.accounts.isEmpty {
                SkeletonView()
            } else if !viewModel.hasAnyAccount {
                emptyState
            } else {
                ScrollView(.vertical) {
                    AccountListView(vm: viewModel)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: Self.listMaxHeight(for: viewModel.informationMode))
            }

            thinDivider

            if viewModel.errorsCount > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("\(viewModel.errorsCount) account(s) with errors")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                thinDivider
            }

            FooterView(vm: viewModel)
        }
        .frame(width: Self.preferredWidth(for: viewModel.informationMode))
        .background(.ultraThinMaterial)
        .background(
            Group {
                Button("") { viewModel.toggleGroupByWorkspace() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("") { viewModel.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }.opacity(0)
        )
    }

    private var thinDivider: some View { Divider().opacity(0.15) }

    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.searchText.isEmpty {
            Text("No account matches '\(viewModel.searchText)'")
                .font(.system(size: 14)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.horizontal, 16)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 32)).foregroundColor(.secondary)
                Text("No accounts found")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                Button {
                    viewModel.addAccount()
                } label: {
                    Label("Add account", systemImage: "person.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.hasPendingAccountAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var vm: UsageViewModel

    var body: some View {
        HStack(spacing: 8) {
            if vm.hasAnyAccount || !vm.searchText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    SearchTextField("Search account...", text: $vm.searchText)
                        .frame(maxWidth: .infinity, minHeight: 16)
                    if !vm.searchText.isEmpty {
                        Button { vm.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06)).cornerRadius(8)
            } else {
                Spacer(minLength: 0)
            }

            Button {
                if vm.isAddingAccount {
                    vm.cancelRelogin()
                } else {
                    vm.addAccount()
                }
            } label: {
                Image(systemName: vm.isAddingAccount ? "xmark.circle.fill" : "person.badge.plus")
                    .font(.system(size: 13))
                    .foregroundColor(vm.isAddingAccount ? .secondary : Color(hex: "30D158"))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(vm.hasPendingAccountAction && !vm.isAddingAccount)
            .help(vm.isAddingAccount ? "Cancel" : "Add account")

            Button {
                vm.toggleInformationMode()
            } label: {
                let isExpanded = vm.informationMode == .complete
                ZStack {
                    Color.clear
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vm.informationMode == .complete ? "Compact view" : "Expand view")

            Button {
                vm.toggleGroupByWorkspace()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundColor(vm.groupByWorkspace ? .primary : .secondary)
                    .frame(width: 28, height: 22)
                    .background(vm.groupByWorkspace ? Color.primary.opacity(0.15) : Color.clear)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help(vm.groupByWorkspace ? "Grouped by workspace" : "Group by workspace")

            Button { vm.refresh() } label: {
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain).frame(width: 22, height: 22)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 44)
    }
}

struct SearchTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ShortcutTextField {
        let field = ShortcutTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: ShortcutTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}

final class ShortcutTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            currentEditor()?.selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var vm: UsageViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(vm.accountActionError ?? timeAgo)
                .font(.system(size: 11))
                .foregroundColor(vm.accountActionError == nil ? .secondary : .orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(vm.isLoading ? 0.5 : 1)

            Spacer(minLength: 16)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(0.75)
            .accessibilityLabel("Quit")
            .help("Quit Codex Switchboard")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(height: 40)
    }

    private var timeAgo: String {
        guard let d = vm.lastRefresh else { return "Not updated yet" }
        if vm.isLoading { return "Updating..." }
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60  { return "Updated now" }
        if s < 3600 { return "Updated \(s / 60)m ago" }
        if s < 86400 { return "Updated \(s / 3600)h ago" }
        return "Updated \(s / 86400)d ago"
    }
}

// MARK: - Skeleton

struct SkeletonView: View {
    @State private var pulse = false

    private let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(pulse ? 0.08 : 0.04))
                    .frame(height: rowHeight)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
