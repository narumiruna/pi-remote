import Foundation
import Testing
@testable import PiRemoteCore

@Test func preservesUnicodeAcrossEveryByteBoundary() throws {
    let line = Data("{\"type\":\"event\",\"text\":\"日本語😀\u{2028}\u{2029}\"}\r\n".utf8)
    for split in 0...line.count {
        var framer = JSONLFramer()
        var records: [JSONValue] = []
        try framer.append(Data(line.prefix(split))) { records.append($0) }
        try framer.append(Data(line.dropFirst(split))) { records.append($0) }
        try framer.finish()
        #expect(records == [.object(["type": .string("event"), "text": .string("日本語😀\u{2028}\u{2029}")])])
    }
}

@Test func acceptsMultipleRecordsInOneRead() throws {
    var framer = JSONLFramer()
    var count = 0
    try framer.append(Data("{\"type\":\"a\"}\n{\"type\":\"b\"}\n".utf8)) { _ in count += 1 }
    try framer.finish()
    #expect(count == 2)
}

@Test(arguments: ["[]\n", "null\n", "\n", "{broken}\n", "{\"x\":\"\n\"}\n"])
func rejectsInvalidRecords(_ text: String) {
    var framer = JSONLFramer()
    #expect(throws: JSONLFailure.invalidRecord) {
        try framer.append(Data(text.utf8)) { _ in }
    }
}

@Test func rejectsInvalidUTF8() {
    var framer = JSONLFramer()
    let data = Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D, 0x0A])
    #expect(throws: JSONLFailure.invalidRecord) { try framer.append(data) { _ in } }
}

@Test func boundsUnterminatedAndCompletedRecords() {
    var framer = JSONLFramer(maximumRecordBytes: 8)
    #expect(throws: JSONLFailure.frameTooLarge) {
        try framer.append(Data("{\"long\":true}\n".utf8)) { _ in }
    }
    #expect(throws: JSONLFailure.invalidRecord) {
        try framer.append(Data("{}\n".utf8)) { _ in }
    }
}

@Test func detectsTruncatedEOF() throws {
    var framer = JSONLFramer()
    try framer.append(Data("{\"type\":".utf8)) { _ in }
    #expect(throws: JSONLFailure.truncatedRecord) { try framer.finish() }
}

@Test func roundTripsUnknownMessageFields() throws {
    let original = JSONValue.object([
        "custom": .array([.bool(true), .null, .number(1.5), .string("unknown")]),
        "future": .object(["field": .number(42)])
    ])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original)) == original)
}
