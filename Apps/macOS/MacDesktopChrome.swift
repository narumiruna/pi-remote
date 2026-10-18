import PiRemoteCore
import SwiftUI

struct MacDesktopHeader: View {
    private let muted = MacInterfaceTheme(mode: .desktop).muted
    let title: String
    let directory: String?
    let phase: String
    let hasSession: Bool

    private var displayedPhase: String { hasSession ? phase : "No session loaded" }

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

            Text(displayedPhase)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .help(displayedPhase)
                .accessibilityLabel("Session phase: \(displayedPhase)")
                .accessibilityIdentifier("desktop-session-phase")
                .frame(maxWidth: 140, alignment: .trailing)
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
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasSession {
                Text("Write an instruction below.")
                    .font(.callout)
                    .foregroundStyle(muted)
                    .accessibilityIdentifier("desktop-empty-hint")
            } else {
                Text("Start with a session")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("desktop-welcome-title")
                Text("Use New session in the toolbar to choose a folder, or resume saved work.")
                    .font(.callout)
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("desktop-welcome-subtitle")
                Button("Resume", systemImage: "clock.arrow.circlepath", action: resume)
                    .buttonStyle(.bordered)
                    .disabled(!canStart)
                    .accessibilityIdentifier("desktop-welcome-resume")
            }
        }
        .foregroundStyle(.primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-welcome")
    }
}

/// Read-only resource metadata from the current snapshot. This view sends no RPC.
struct MacDesktopSessionResources: View {
    let state: HostSnapshot
    private let muted = MacInterfaceTheme(mode: .desktop).muted

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            resourceLine("Context", value: "Loaded context paths are not reported by Pi RPC.")
            resourceLine("Skills", value: PiStartupResources.names(source: "skill", commands: state.commands).joined(separator: ", "))
            resourceLine("Prompts", value: PiStartupResources.names(source: "prompt", commands: state.commands).joined(separator: ", "))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-session-resources")
    }

    private func resourceLine(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(muted)
            Text(value.isEmpty ? "No entries reported by Pi." : value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("desktop-resource-" + label.lowercased())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Legacy notices have no severity. Do not infer it from their text.
struct MacDesktopDiagnosticCounts: Equatable {
    let errors: Int
    let warnings: Int
    let information: Int
    let legacy: Int
    let texts: [String]
    let recovery: [ExtensionNotice]

    init(state: HostSnapshot) {
        let notices = state.extensionDisplay?.notices ?? []
        // The host reserves this ID for required recovery instructions, not diagnostics.
        recovery = notices.filter { $0.id == "recovery" }
        let diagnostics = notices.filter { $0.id != "recovery" }
        errors = diagnostics.filter { $0.severity == .error }.count
        warnings = diagnostics.filter { $0.severity == .warning }.count
        information = diagnostics.filter { $0.severity == .info }.count
        let display = state.extensionDisplay
        // Legacy snapshots also mirror widget/status text. Those entries already
        // have their own presentation and are not unknown-severity notices.
        let typedText = Set(notices.map(\.text) + (display?.statuses.map(\.text) ?? []) + (display?.widgets.map(\.text) ?? []))
        let unmatched = state.notices.filter { !typedText.contains($0) }
        legacy = unmatched.count
        texts = notices.map(\.text) + unmatched
    }

    var total: Int { errors + warnings + information + legacy }
    var needsAttention: Bool { errors > 0 || warnings > 0 }
    var text: String {
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) " + (errors == 1 ? "error" : "errors")) }
        if warnings > 0 { parts.append("\(warnings) " + (warnings == 1 ? "warning" : "warnings")) }
        if information > 0 { parts.append("\(information) info") }
        if legacy > 0 { parts.append("\(legacy) " + (legacy == 1 ? "notice" : "notices") + " (severity unavailable)") }
        return parts.joined(separator: " · ")
    }
}

struct MacDesktopDiagnostics: View {
    let state: HostSnapshot
    let openControls: (String) -> Bool
    private let theme = MacInterfaceTheme(mode: .desktop)

    var body: some View {
        let counts = MacDesktopDiagnosticCounts(state: state)
        if counts.total > 0 || !counts.recovery.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(counts.recovery) { notice in
                    Text(notice.severity.rawValue.capitalized + ": " + notice.text)
                        .font(.callout)
                        .foregroundStyle(theme.warning)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("desktop-recovery-notice")
                }
                if counts.total > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(counts.text)
                            .font(.callout)
                            .foregroundStyle(counts.needsAttention ? theme.warning : theme.muted)
                            .accessibilityIdentifier("desktop-diagnostics-summary")
                        Spacer(minLength: 0)
                        Button("View details") { _ = openControls("activity") }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("desktop-diagnostics-details")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("desktop-diagnostics")
        }
    }
}
