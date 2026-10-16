import PiRemoteCore
import SwiftUI

struct MarkdownContent: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownDocument(text).blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    if block.quoted { Rectangle().fill(.secondary).frame(width: 3).accessibilityHidden(true) }
                    if let marker = block.marker { Text(marker).monospacedDigit().accessibilityHidden(true) }
                    content(block)
                }
                .padding(.leading, CGFloat(max(0, block.indent - 1)) * 16)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
    @ViewBuilder private func content(_ block: MarkdownDocument.Block) -> some View {
        switch block.kind {
        case .paragraph: Text(block.text).textSelection(.enabled)
        case .heading(let level):
            Text(block.text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader).textSelection(.enabled)
        case .code:
            VStack(alignment: .leading, spacing: 4) {
                if let language = block.language, !language.isEmpty { Text(language).font(.caption).foregroundStyle(.primary.opacity(0.75)) }
                ScrollView(.horizontal) {
                    Text(String(block.text.characters)).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).padding(12)
                }.background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        case .rule: Divider()
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell).fontWeight(row == 0 ? .semibold : .regular).textSelection(.enabled)
                            }
                        }
                        if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(8)
            }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
