import Foundation

/// Insert an explicitly selected text preview without overwriting the draft.
public enum TextAttachment {
    public static func append(_ preview: FilePreview, to draft: String) throws -> String {
        guard draft.utf8.count <= 256 * 1_024, preview.name.utf8.count <= 512, preview.text.utf8.count <= 256 * 1_024 else { throw RemoteFault.tooLarge }
        let name = preview.name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        var longest = 0, run = 0
        for character in preview.text {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let notice = preview.truncated ? "[Partial file: only the displayed preview is attached.]\n" : ""
        let result = draft + (draft.isEmpty ? "" : "\n\n") + "File: " + name + "\n" + notice + fence + "\n" + preview.text + "\n" + fence
        guard result.utf8.count <= 256 * 1_024 else { throw RemoteFault.tooLarge }
        return result
    }
}
