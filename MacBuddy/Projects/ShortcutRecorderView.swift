import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var hotKey: HotKeySpec?
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                recorderLabel
            }
            .buttonStyle(.plain)
            .background {
                ShortcutCaptureView(isRecording: $isRecording, onEvent: handleRecordedEvent)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }

            if hotKey != nil, !isRecording {
                Button(action: clear) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut")
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        .onDisappear(perform: stopRecording)
    }

    @ViewBuilder
    private var recorderLabel: some View {
        if isRecording {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.alarmRed)
                    .frame(width: 6, height: 6)
                    .opacity(0.9)
                Text("TYPE KEYS…")
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.alarmRed.opacity(0.1), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.alarmRed.opacity(0.5)))
        } else if let hotKey {
            KeycapRow(hotKey)
                .help("Click to re-record")
        } else {
            Text("RECORD")
                .font(Theme.mono(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.strokeBright))
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
