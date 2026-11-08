import SwiftUI

struct TranslatorCard: View {
    @Environment(TranslatorService.self) private var translator
    let focusToken: Int
    let onEscape: () -> Void
    let openSettings: () -> Void

    private var showsResult: Bool {
        switch translator.phase {
        case .idle: false
        case .translating: true
        case .done: !translator.output.isEmpty
        case .needsLanguages, .failed: true
        }
    }

    /// At rest: a bare, slim line — no icon, no hint, no buttons. It grows only once there is text.
    static let restingHeight: CGFloat = 28

    var body: some View {
        @Bindable var translator = translator
        let hasText = !translator.input.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PasteField(text: $translator.input,
                           placeholder: "",
                           focusToken: focusToken,
                           onSubmit: translator.copyOutput,
                           onEscape: onEscape)
                if hasText {
                    Button(action: translator.flipDirection) {
                        Text(translator.direction.label)
                            .font(.system(size: 10, weight: .semibold).monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Поменять направление")
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .frame(height: hasText ? 36 : Self.restingHeight)
            .padding(.horizontal, 12)

            if showsResult {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                result
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .card(radius: hasText ? 16 : Self.restingHeight / 2, quiet: !hasText)
        .animation(Motion.resize, value: hasText)
        .animation(.smooth(duration: 0.2), value: translator.direction)
    }

    @ViewBuilder private var result: some View {
        switch translator.phase {
        case .needsLanguages:
            HStack(spacing: 10) {
                Text(translator.isDownloading ? "Скачиваю русский и английский…"
                     : "Один раз скачай русский и английский — дальше перевод работает офлайн.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if translator.isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Скачать") {
                        translator.startDownload()
                        openSettings()
                    }
                    .buttonStyle(PressableStyle())
                    .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        case .failed:
            Text("Не получилось перевести. Попробуй ещё раз.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        case .translating where translator.output.isEmpty:
            Text("Перевожу…")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        default:
            CopyableResult(text: translator.output,
                           stale: translator.phase == .translating,
                           copiedAt: translator.copiedAt,
                           copy: translator.copyOutput)
        }
    }
}

/// The whole translation row is one target: a click anywhere copies the translation.
private struct CopyableResult: View {
    let text: String
    let stale: Bool
    let copiedAt: Date?
    let copy: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .top, spacing: 10) {
                Text(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(stale ? 0.55 : 1)
                HStack(spacing: 4) {
                    if copied {
                        Text("Скопировано")
                            .font(.system(size: 11, weight: .semibold))
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .foregroundStyle(copied ? AnyShapeStyle(Palette.green)
                                 : AnyShapeStyle(hovering ? .primary : .secondary))
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(copied ? Palette.green.opacity(0.16) : Color.primary.opacity(hovering ? 0.06 : 0))
                    .padding(4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .onHover { hovering = $0 }
        .help("Нажми, чтобы скопировать перевод (или ↩)")
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: copied)
        .onChange(of: copiedAt) { _, newValue in
            resetTask?.cancel()
            guard newValue != nil else { copied = false; return }
            copied = true
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.3))
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
    }
}
