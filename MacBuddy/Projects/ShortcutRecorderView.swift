import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var hotKey: HotKeySpec?
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    if isRecording {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating, isActive: isRecording)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                    Text(buttonTitle)
                        .contentTransition(.opacity)
                }
                .frame(minWidth: 140)
                .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
            .background {
                ShortcutCaptureView(isRecording: $isRecording, onEvent: handleRecordedEvent)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }

            if hotKey != nil, !isRecording {
                Button("Clear shortcut", systemImage: "xmark.circle.fill", action: clear)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording {
            "Type shortcut…"
        } else {
            hotKey?.displayString ?? "Record Shortcut"
        }
    }

    private func toggleRecording() {
        isRecording.toggle()
    }

    private func handleRecordedEvent(_ event: NSEvent) {
        let isPlainEscape = event.keyCode == 53
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if isPlainEscape {
            stopRecording()
            return
        }
        guard let spec = HotKeySpec(event: event) else { return }
        hotKey = spec
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
    }

    private func clear() {
        hotKey = nil
    }
}
