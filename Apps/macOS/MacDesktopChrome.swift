import SwiftUI

struct MacDesktopHeader: View {
    private let muted = MacInterfaceTheme(mode: .desktop).muted
    let title: String
    let directory: String?
    let phase: String
    let hasSession: Bool
    let openSession: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .help(title)
                    .accessibilityIdentifier("desktop-session-title")
                if let directory, !directory.isEmpty {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory)
                        .accessibilityIdentifier("desktop-session-directory")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Text(phase)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .help(phase)
                    .accessibilityLabel("Session phase: \(phase)")
                    .accessibilityIdentifier("desktop-session-phase")
                    .frame(maxWidth: 140, alignment: .trailing)
                Button("Session controls", action: openSession)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasSession)
                    .accessibilityIdentifier("desktop-session-controls")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-session-header")
    }
}

struct MacDesktopWelcome: View {
    private let muted = MacInterfaceTheme(mode: .desktop).muted
    let hasSession: Bool
    let canStart: Bool
    let newSession: () -> Void
    let resume: () -> Void
    let openFiles: () -> Void
    let openCommands: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 6) {
                Text("π")
                    .font(.system(size: 48, weight: .medium))
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(muted)
                    .padding(.top, 6)
            }
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(hasSession ? "Ready when you are" : "Start with a session")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("desktop-welcome-title")
                Text(hasSession
                     ? "Write an instruction below, or explore files and commands."
                     : "Choose a folder for a new session, or resume saved work.")
                    .font(.body)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("desktop-welcome-subtitle")
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                if hasSession {
                    Button("Files", systemImage: "folder", action: openFiles)
                        .accessibilityIdentifier("desktop-welcome-files")
                    Button("Commands", systemImage: "command", action: openCommands)
                        .accessibilityIdentifier("desktop-welcome-commands")
                } else {
                    Button("New session", systemImage: "plus", action: newSession)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("desktop-welcome-new-session")
                    Button("Resume", systemImage: "clock.arrow.circlepath", action: resume)
                        .accessibilityIdentifier("desktop-welcome-resume")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!hasSession && !canStart)
        }
        .foregroundStyle(.primary)
        .padding(24)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-welcome")
    }
}
