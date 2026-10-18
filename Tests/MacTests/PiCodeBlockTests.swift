import AppKit
import SwiftUI
import XCTest

@MainActor final class PiCodeBlockTests: XCTestCase {
    func testSupportedLanguagesAndAliasesPreserveExactUTF8() {
        let fixtures = [
            ("swift", "let café = \"😀 e\u{301}\"\r\n// comment\n"),
            ("js", "const answer = 42; // comment\n"),
            ("javascript", "const answer = 42;"),
            ("jsx", "const answer = 42;"),
            ("ts", "interface Item { readonly count: number }"),
            ("typescript", "let answer = 42;"),
            ("tsx", "const answer = 42;"),
            ("py", "def answer():\n    return True # comment\n"),
            ("python", "answer = None"),
            ("python3", "answer = False"),
            ("json", "{\"answer\": 42, \"enabled\": true, \"missing\": null}"),
            ("SWIFT", "let answer = 42")
        ]
        for (language, code) in fixtures {
            let runs = PiCodeSyntax.runs(code: code, language: language)
            assertExact(code, runs)
            XCTAssertTrue(runs.contains { $0.kind != .plain }, language)
        }
    }

    func testEscapedStringsKeepCommentMarkersInsideStrings() {
        let swift = #"let text = "escaped \" // not a comment" // real comment"#
        let runs = PiCodeSyntax.runs(code: swift, language: "swift")
        assertExact(swift, runs)
        XCTAssertEqual(runs.filter { $0.kind == .string }.map(\.text), [#""escaped \" // not a comment""#])
        XCTAssertEqual(runs.filter { $0.kind == .comment }.map(\.text), ["// real comment"])

        let python = #"text = 'escaped \' # not a comment' # real comment"#
        let pythonRuns = PiCodeSyntax.runs(code: python, language: "python")
        assertExact(python, pythonRuns)
        XCTAssertEqual(pythonRuns.filter { $0.kind == .comment }.map(\.text), ["# real comment"])

        let json = #"{"text":"escaped \" // still a string"}"#
        let jsonRuns = PiCodeSyntax.runs(code: json, language: "json")
        assertExact(json, jsonRuns)
        XCTAssertFalse(jsonRuns.contains { $0.kind == .comment })
    }

    func testCommentsAndMultilineStringsRemainWhole() {
        let swift = "/* outer /* inner */ still comment */\nlet text = \"\"\"\n// string 😀\n\"\"\""
        let runs = PiCodeSyntax.runs(code: swift, language: "swift")
        assertExact(swift, runs)
        XCTAssertEqual(runs.filter { $0.kind == .comment }.map(\.text), ["/* outer /* inner */ still comment */"])
        XCTAssertEqual(runs.filter { $0.kind == .string }.map(\.text), ["\"\"\"\n// string 😀\n\"\"\""])

        let python = "text = '''\n# string\n'''\n# comment"
        let pythonRuns = PiCodeSyntax.runs(code: python, language: "python")
        assertExact(python, pythonRuns)
        XCTAssertEqual(pythonRuns.filter { $0.kind == .comment }.map(\.text), ["# comment"])

        let js = "const text = `line one\n// string ${value}`; /* comment */"
        let jsRuns = PiCodeSyntax.runs(code: js, language: "js")
        assertExact(js, jsRuns)
        XCTAssertEqual(jsRuns.filter { $0.kind == .string }.map(\.text), ["`line one\n// string ${value}`"])
        XCTAssertEqual(jsRuns.filter { $0.kind == .comment }.map(\.text), ["/* comment */"])
    }

    func testIncompleteTokensAndUnicodeNeverLoseSource() {
        for language in ["swift", "js", "ts", "python", "json"] {
            for code in ["", "\"", "\"unfinished\\", "'unfinished", "/* unfinished 😀", "// unfinished\r\n", "# 😀", "1.2e-", "let café变量 = \"e\u{301}😀\"", "\"\"\"unterminated\n😀", "`unterminated\\", "\u{0} trailing\n"] {
                assertExact(code, PiCodeSyntax.runs(code: code, language: language))
            }
        }
    }

    func testUnknownAndShellLanguagesStayPlain() {
        let code = "<script>let text = \"https://example.invalid\"</script>\n"
        for language: String? in [nil, "", "unknown", "html", "bash", "sh", "swift title=untrusted", String(repeating: "s", count: 100_000)] {
            XCTAssertEqual(PiCodeSyntax.runs(code: code, language: language), [.init(text: code, kind: .plain)])
        }
        let rawSwift = ##"let text = #"raw \" // still a string"#"##
        XCTAssertEqual(PiCodeSyntax.runs(code: rawSwift, language: "swift"), [.init(text: rawSwift, kind: .plain)])
    }

    func testByteAndRunBoundsFallBackToExactPlainText() {
        let atLimit = "let x = 1" + String(repeating: " ", count: PiCodeSyntax.maximumBytes - 9)
        XCTAssertEqual(atLimit.utf8.count, PiCodeSyntax.maximumBytes)
        let runs = PiCodeSyntax.runs(code: atLimit, language: "swift")
        XCTAssertTrue(runs.contains { $0.kind == .keyword })
        assertExact(atLimit, runs)
        for code in [atLimit + " ", String(repeating: "😀", count: PiCodeSyntax.maximumBytes / 4 + 1),
                     String(repeating: "let x = 1; ", count: PiCodeSyntax.maximumRuns)] {
            XCTAssertEqual(PiCodeSyntax.runs(code: code, language: "swift"), [.init(text: code, kind: .plain)])
        }
    }

    func testNumbersAndKeywordBoundariesAreConservative() {
        let code = "let letter = 12.5e-2; let cafélet = true; let letdown = 4"
        let runs = PiCodeSyntax.runs(code: code, language: "swift")
        assertExact(code, runs)
        XCTAssertEqual(runs.filter { $0.kind == .keyword }.map(\.text), ["let", "let", "true", "let"])
        XCTAssertEqual(runs.filter { $0.kind == .number }.map(\.text), ["12.5e-2", "4"])
    }

    func testShortCodeAlignsWithTheLeadingViewportEdge() async throws {
        try await hosted(PiCodeBlock(code: "let x = 1", language: "swift", copy: { _ in XCTFail("Render must not copy") })) { host, _ in
            let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            let frame = document.convert(document.bounds, to: scroll)
            XCTAssertEqual(frame.minX, scroll.bounds.minX, accuracy: 1, "Short code must not be centered in a wide viewport.")
        }
    }

    func testNativeRenderDoesNotCopyAndLongCodeScrolls() async throws {
        let code = "let text = \"" + String(repeating: "界😀", count: 200) + "\"\n" + String(repeating: "// line\n", count: 30)
        var copies: [String] = []
        try await hosted(PiCodeBlock(code: code, language: "swift", copy: { copies.append($0) }), width: 360) { host, _ in
            XCTAssertTrue(copies.isEmpty)
            XCTAssertNil(self.find("pi-code-copy-feedback", in: host))
            XCTAssertNotNil(self.find("pi-code-copy", in: host))
            let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first)
            XCTAssertLessThanOrEqual(scroll.bounds.height, 308)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.width, scroll.contentView.bounds.width)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
        }
    }

    func testNativeCopyCanRepeatAndPreservesRawSource() async throws {
        let code = "let café = \"😀 e\u{301}\"\r\n\n"
        var copies: [String] = []
        try await hosted(PiCodeBlock(code: code, language: "swift", copy: { copies.append($0) })) { host, _ in
            XCTAssertTrue(copies.isEmpty)
            for count in 1...2 {
                try await self.pressCopy(in: host)
                XCTAssertEqual(copies.count, count)
                XCTAssertEqual(Array(try XCTUnwrap(copies.last).utf8), Array(code.utf8))
                XCTAssertEqual(self.feedback(in: host), "Copied to this Mac")
            }
        }
    }

    func testNativeCopyFailureReplacesSuccessWithoutRawErrorAndCanRetry() async throws {
        struct PrivateFailure: LocalizedError {
            var errorDescription: String? { "PRIVATE_RAW_ERROR_DO_NOT_DISPLAY" }
        }
        var attempts = 0
        var fail = false
        try await hosted(PiCodeBlock(code: "exact source", language: nil, copy: { _ in
            attempts += 1
            if fail { throw PrivateFailure() }
        })) { host, _ in
            XCTAssertEqual(attempts, 0)
            try await self.pressCopy(in: host)
            XCTAssertEqual(self.feedback(in: host), "Copied to this Mac")
            fail = true
            try await self.pressCopy(in: host)
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(self.feedback(in: host), "Cannot copy code. Try again.")
            XCTAssertFalse(self.nodes(in: host).contains {
                (self.value("accessibilityValue", of: $0) as? String ?? "").contains("PRIVATE_RAW_ERROR")
            })
            fail = false
            try await self.pressCopy(in: host)
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(self.feedback(in: host), "Copied to this Mac")
        }
    }

    func testNativeSourceUpdateClearsFeedbackWithoutCopying() async throws {
        var copies: [String] = []
        let copy: (String) throws -> Void = { copies.append($0) }
        try await hosted(PiCodeBlock(code: "let first = 1", language: "swift", copy: copy)) { host, _ in
            try await self.pressCopy(in: host)
            host.rootView = PiCodeBlock(code: "second raw source\n", language: "unknown", copy: copy)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(copies, ["let first = 1"])
            XCTAssertNil(self.find("pi-code-copy-feedback", in: host))
            try await self.pressCopy(in: host)
            XCTAssertEqual(copies, ["let first = 1", "second raw source\n"])
        }
    }

    private func assertExact(_ code: String, _ runs: [PiCodeSyntax.Run], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(runs.map(\.text).joined().utf8), Array(code.utf8), file: file, line: line)
        XCTAssertLessThanOrEqual(runs.count, PiCodeSyntax.maximumRuns, file: file, line: line)
    }

    private func hosted(_ view: PiCodeBlock, width: CGFloat = 520,
                        exercise: (NSHostingView<PiCodeBlock>, NSWindow) async throws -> Void) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 370), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        try await exercise(host, window)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func value(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector) { return object.perform(selector)?.takeUnretainedValue() }
        let attributes = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityValue": "AXValue", "accessibilityLabel": "AXDescription", "accessibilityParent": "AXParent"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    private func nodes(in root: NSView) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in value("accessibilityChildren", of: object) as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        if let window = root.window {
            for y in stride(from: CGFloat(6), to: root.bounds.height, by: 12) {
                for x in stride(from: CGFloat(6), to: root.bounds.width, by: 40) {
                    let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                    if let hit = root.accessibilityHitTest(point) as? NSObject {
                        visit(hit)
                        var parent = value("accessibilityParent", of: hit) as? NSObject
                        var ancestors = Set<ObjectIdentifier>()
                        while let object = parent, ancestors.insert(ObjectIdentifier(object)).inserted {
                            visit(object)
                            parent = value("accessibilityParent", of: object) as? NSObject
                        }
                    }
                }
            }
        }
        return result
    }

    private func find(_ identifier: String, in root: NSView) -> NSObject? {
        nodes(in: root).first { value("accessibilityIdentifier", of: $0) as? String == identifier }
    }

    private func feedback(in root: NSView) -> String? {
        find("pi-code-copy-feedback", in: root).flatMap { value("accessibilityValue", of: $0) as? String }
    }

    private func pressCopy(in root: NSView) async throws {
        if let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Copy code" }) {
            button.performClick(nil)
        } else {
            let dump = nodes(in: root).map {
                "\(type(of: $0)): id=\(value("accessibilityIdentifier", of: $0) ?? "nil") label=\(value("accessibilityLabel", of: $0) ?? "nil") value=\(value("accessibilityValue", of: $0) ?? "nil")"
            }.joined(separator: "\n")
            let button = try XCTUnwrap(find("pi-code-copy", in: root), "Missing Copy code control.\n" + dump)
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(button.responds(to: selector))
            guard button.responds(to: selector) else { return }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
        }
        try await Task.sleep(for: .milliseconds(150))
        root.layoutSubtreeIfNeeded()
    }
}
