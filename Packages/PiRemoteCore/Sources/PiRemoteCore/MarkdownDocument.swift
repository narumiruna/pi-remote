import Foundation

/// Use Foundation's Markdown parser; preserve inline attributes while grouping native blocks.
public struct MarkdownDocument: Sendable {
    public struct Block: Identifiable, Sendable {
        public enum Kind: Sendable, Equatable { case paragraph, heading(Int), code, rule, table }
        public var id: Int
        public var kind: Kind
        public var text: AttributedString
        public var marker: String?
        public var indent: Int
        public var quoted: Bool
        public var language: String?
        public var rows: [[AttributedString]] = []
    }
    public var blocks: [Block]

    public init(_ source: String) {
        guard let parsed = try? AttributedString(markdown: source) else {
            blocks = [Block(id: 0, kind: .paragraph, text: AttributedString(source), indent: 0, quoted: false)]
            return
        }
        struct Atom { var id: Int; var text: AttributedString; var intent: PresentationIntent? }
        var atoms: [Atom] = []
        for run in parsed.runs {
            let id = run.presentationIntent?.components.first?.identity ?? 0
            let text = AttributedString(parsed[run.range])
            if atoms.last?.id == id { atoms[atoms.count - 1].text.append(text) }
            else { atoms.append(Atom(id: id, text: text, intent: run.presentationIntent)) }
        }
        blocks = []
        var seenItems: Set<Int> = []
        var tableRows: [Int: Int] = [:]
        for atom in atoms {
            let components = atom.intent?.components ?? []
            var block = Block(id: atom.id, kind: .paragraph, text: atom.text, indent: 0, quoted: false)
            var ordinal: Int?, itemID: Int?, ordered = false
            var tableID: Int?, rowID: Int?, column = 0
            for component in components {
                switch component.kind {
                case .header(let level): block.kind = .heading(level)
                case .codeBlock(let language): block.kind = .code; block.language = language
                case .thematicBreak: block.kind = .rule
                case .blockQuote: block.quoted = true
                case .listItem(let value):
                    if ordinal == nil { ordinal = value; itemID = component.identity }
                    block.indent += 1
                case .orderedList: if block.indent == 1 { ordered = true }
                case .table: tableID = component.identity
                case .tableRow, .tableHeaderRow: rowID = component.identity
                case .tableCell(let value): column = value
                default: break
                }
            }
            if let itemID, seenItems.insert(itemID).inserted { block.marker = ordered ? "\(ordinal ?? 1)." : "•" }
            if let tableID, let rowID {
                if blocks.last?.id != tableID {
                    blocks.append(Block(id: tableID, kind: .table, text: AttributedString(), indent: block.indent, quoted: block.quoted))
                    tableRows = [:]
                }
                let index = blocks.count - 1
                let row = tableRows[rowID] ?? blocks[index].rows.count
                tableRows[rowID] = row
                if blocks[index].rows.count == row { blocks[index].rows.append([]) }
                // Preserve the source instead of silently dropping an oversized table.
                guard column >= 0, column < 256 else {
                    blocks = [Block(id: 0, kind: .paragraph,
                                    text: AttributedString("Table exceeds the layout limit. Raw Markdown:\n" + source),
                                    indent: 0, quoted: false)]
                    return
                }
                while blocks[index].rows[row].count <= column { blocks[index].rows[row].append(AttributedString()) }
                blocks[index].rows[row][column].append(atom.text)
            } else { blocks.append(block) }
        }
    }
}
