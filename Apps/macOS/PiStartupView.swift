import PiRemoteCore
import SwiftUI

/// Source-based Pi startup layout. Resource names come only from RPC discovery.
struct PiStartupView: View {
    let state: HostSnapshot
    let expanded: Bool
    let newSession: () -> Void
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                PiStartupLogo().frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.piVersion == "Not running" ? "Pi is not running" : "v" + state.piVersion)
                    Text("esc interrupt · / commands · ! bash · ctrl+o more")
                }
            }
            Text("Press ctrl+o to show full startup help and tool output.")
                .padding(.top, 3)
            Text("Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.")
                .padding(.top, 24)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text("enter send/steer · option+enter follow-up · shift+enter newline")
                    Text("tab complete · ctrl+l model · shift+tab thinking · ctrl+t thinking text")
                    Text("option+up recover queued input · cmd+shift+o resume sessions")
                }.padding(.top, 16)
            }
            if state.selected == nil {
                HStack(spacing: 20) {
                    Button("New session…", action: newSession)
                    Button("Resume…", action: resume)
                }.buttonStyle(.plain).foregroundStyle(PiPalette.accent).padding(.top, 16)
            }
            resourceSection("Context", text: "Loaded context paths are not reported by Pi RPC.")
            resourceSection("Skills", text: names(source: "skill"))
            resourceSection("Prompts", text: names(source: "prompt"))
            if state.commands.count >= 256 {
                Text("The reported command list is bounded. Use Commands to inspect available entries.")
                    .padding(.top, 8)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(PiPalette.muted)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pi-startup")
    }

    private func resourceSection(_ name: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("[" + name + "]").foregroundStyle(PiPalette.heading)
            Text(text).padding(.leading, 16)
                .accessibilityIdentifier("pi-startup-" + name.lowercased())
        }.padding(.top, 24)
    }

    private func names(source: String) -> String {
        guard state.selected != nil else { return "Available after Pi starts." }
        let names = PiStartupResources.names(source: source, commands: state.commands)
        return names.isEmpty ? "No entries in Pi's reported command list." : names.joined(separator: ", ")
    }
}

enum PiStartupResources {
    static func names(source: String, commands: [CommandOption]) -> [String] {
        var seen = Set<String>()
        return commands.filter { $0.source == source }.compactMap { command in
            guard !command.name.isEmpty else { return nil }
            let name: String
            if source == "skill" {
                name = command.name.hasPrefix("skill:") ? String(command.name.dropFirst(6)) : command.name
            } else { name = "/" + command.name }
            guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil,
                  seen.insert(name).inserted else { return nil }
            return name
        }
    }
}

private struct PiStartupLogo: View {
    var body: some View {
        Canvas { context, size in
            let coral = Color(red: 228 / 255, green: 138 / 255, blue: 122 / 255)
            let blue = Color(red: 79 / 255, green: 142 / 255, blue: 179 / 255)
            let yellow = Color(red: 234 / 255, green: 182 / 255, blue: 93 / 255)
            let pixels: [[Color?]] = [
                [coral, coral, coral, nil],
                [blue, nil, coral, nil],
                [blue, blue, nil, yellow],
                [blue, nil, nil, yellow]
            ]
            for row in pixels.indices {
                for column in pixels[row].indices {
                    if let color = pixels[row][column] {
                        context.fill(Path(CGRect(x: CGFloat(column) * size.width / 4,
                                                 y: CGFloat(row) * size.height / 4,
                                                 width: size.width / 4, height: size.height / 4)), with: .color(color))
                    }
                }
            }
        }
    }
}
