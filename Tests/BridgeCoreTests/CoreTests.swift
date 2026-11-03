import Foundation
import BridgeCore
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Equality check failed") }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a != b, "Inequality check failed") }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value(); preconditionFailure("Expected failure") } catch {}
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw BridgeError.message("Missing value") }; return value
}
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ event: ReadProgress) {
        if case .fetching(let done, _) = event { lock.lock(); values.append(done); lock.unlock() }
    }
    func last() -> Int? { lock.lock(); defer { lock.unlock() }; return values.last }
}
@main struct CoreTests {
    static func testCSVPreservesSecretsAndQuotedNewlines() throws {
        let csv = "\u{feff}Title,URL,Username,Password,Notes\r\n\"A,B\",https://example.com,User,\" x\"\"y \",\"line1\nline2\"\r\n"
        let e = try XCTUnwrap(CSV.entries(csv).first)
        XCTAssertEqual(e.title, "A,B"); XCTAssertEqual(e.password, " x\"y "); XCTAssertEqual(e.notes, "line1\nline2")
    }
    static func testMalformedOrUnknownFieldsStopImport() {
        XCTAssertThrowsError(try CSV.parse("a,\"unterminated"))
        XCTAssertThrowsError(try CSV.entries("URL,Username,Password,Extra\na,b,c,d"))
        XCTAssertThrowsError(try CSV.entries("URL,Username,Password\na,b"))
    }
    static func entry(_ password: String, url: String = "https://example.com", user: String = "User", notes: String = "") -> Entry {
        Entry(title: "test", url: url, username: user, password: password, notes: notes)
    }
    static func testConflictingTargetCannotBeClassifiedAsSafeEvenWithMatchingCopy() {
        let a = entry("current")
        XCTAssertEqual(compare([a], [entry("current"), entry("old")])[0].verdict, .conflict)
    }
    static func testAppleInternalConflictBlocksBothRows() {
        XCTAssertEqual(compare([entry("old"), entry("new")], []).map(\.verdict), [.conflict, .conflict])
    }
    static func testExactDuplicatesAndNotes() {
        XCTAssertEqual(compare([entry("a"), entry("a")], []).map(\.verdict), [.new, .duplicate])
        XCTAssertEqual(compare([entry("a", notes: "important")], [entry("a")])[0].verdict, .metadata)
    }
    static func testConservativeIdentity() {
        XCTAssertEqual(entry("a", url: "https://EXAMPLE.com/").identity, entry("a").identity)
        XCTAssertNotEqual(entry("a", user: "user").identity, entry("a").identity)
        XCTAssertNotEqual(entry("a", url: "https://login.example.com").identity, entry("a").identity)
        XCTAssertNotEqual(entry("a", url: "https://example.com/other").identity, entry("a").identity)
    }
    static func testCLIUsingFakeExecutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-op")
        let json = #"{"id":"fake-item","title":"test","urls":[{"href":"https://example.com"}],"fields":[{"id":"username","value":"User"},{"id":"password","value":"a"},{"id":"notesPlain","value":""}]}"#
        let text = "#!/bin/sh\nif [ \"$2\" = list ]; then echo '[]'; else\nif [ \"$2\" = create ]; then cat >/dev/null; fi\nprintf '%s' '" + json + "'\nfi\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = OPClient(executable: script.path, account: "fake-account", vault: "fake-vault")
        XCTAssertEqual(try client.read().count, 0)
        XCTAssertEqual(try client.createAndVerify(entry("a")), "fake-item")
        XCTAssertThrowsError(try OPClient(executable: "/usr/bin/false", account: "fake", vault: "fake").read())
    }
    static func testLargeComparison() {
        let entries = (0..<10000).map { Entry(title: "test", url: "https://site\($0).example.com", username: "demo", password: "synthetic") }
        let start = Date()
        let results = compare(entries, [])
        XCTAssertEqual(results.count, 10000)
        XCTAssertEqual(results.filter { $0.verdict == .new }.count, 10000)
        let seconds = Date().timeIntervalSince(start)
        precondition(seconds < 3, "10,000 row comparison took too long")
        print("10,000 synthetic rows: \(String(format: "%.3f", seconds))s")
    }
    static func testBatchedReadingAndInterruption() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-op")
        let text = #"""
        #!/usr/bin/python3
        import sys, json, os, time
        root = os.path.dirname(__file__)
        modefile = os.path.join(root, 'mode')
        mode = open(modefile).read() if os.path.exists(modefile) else 'ok'
        action = sys.argv[2]
        with open(os.path.join(root, 'calls'), 'a') as f: f.write(action + '\n')
        if action == 'list':
            print(json.dumps([{'id': 'item-' + str(i)} for i in range(123)]))
        else:
            ids = json.load(sys.stdin)
            if mode == 'slow': time.sleep(10)
            if mode == 'fail': sys.exit(1)
            if mode == 'missing': ids = ids[1:]
            for e in ids:
                print(json.dumps({'id': e['id'], 'title': 'Synthetic', 'urls': [{'href': 'https://' + e['id'] + '.example.com'}], 'fields': [{'id': 'username', 'value': 'demo'}, {'id': 'password', 'value': 'synthetic'}]}, indent=2))
        """#
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = OPClient(executable: script.path, account: "fake", vault: "fake")
        let log = ProgressLog()
        let results = try await client.readFast(control: ReadControl()) { log.add($0) }
        XCTAssertEqual(results.count, 123)
        XCTAssertEqual(log.last(), 123)
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.filter { $0 == "list" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "get" }.count, 3)
        for mode in ["missing", "fail"] {
            try mode.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            do { _ = try await client.readFast(control: ReadControl()) { _ in }; preconditionFailure("Incomplete read accepted") }
            catch is CancellationError { preconditionFailure("Read failure reported as user cancellation") }
            catch { /* Expected: no partial success. */ }
        }
        try "slow".write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let control = ReadControl(), start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { control.cancel() }
        do { _ = try await client.readFast(control: control) { _ in }; preconditionFailure("Cancelled read accepted") }
        catch is CancellationError {} catch { preconditionFailure("Expected cancellation") }
        precondition(Date().timeIntervalSince(start) < 3, "Cancel did not terminate subprocess")
        let timeoutClient = OPClient(executable: script.path, account: "fake", vault: "fake", commandTimeout: 0.3)
        let timeoutStart = Date()
        do { _ = try timeoutClient.read(); preconditionFailure("Timeout accepted") }
        catch { precondition(error.localizedDescription.contains("制限時間"), "Wrong timeout error") }
        precondition(Date().timeIntervalSince(timeoutStart) < 3, "Timeout did not terminate subprocess")
        print("Batching: 123 items in 3 get processes; missing/failure/cancel/timeout checks passed")
    }
    static func testJSONStreams() throws {
        let a = #"{"id":"a","notes":"a } { [ \" escaped\\\" 日本語\nnewline"}"#
        let b = #"{"id":"b","fields":[{"value":"x"}]}"#
        for input in ["[" + a + "," + b + "]", a + "\n" + b, a + "\r\n\n" + b] {
            let items = try CLIJSON.items(Data(input.utf8))
            XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["a", "b"])
        }
        let pretty = "{\n  \"id\": \"a\"\n}\n{\n  \"id\": \"b\"\n}"
        XCTAssertEqual(try CLIJSON.items(Data(pretty.utf8)).count, 2)
        XCTAssertEqual(try CLIJSON.items(Data(a.utf8)).count, 1)
        XCTAssertEqual(try CLIJSON.items(Data("[]".utf8)).count, 0)
        for invalid in ["", a + "\n{", a + "\nERROR", "[1]", "null", "{]", a + b] {
            XCTAssertThrowsError(try CLIJSON.items(Data(invalid.utf8)))
        }
    }
    static func testRelatedURLsPreventDuplicateCreation() {
        let target = entry("same", url: "https://reading.example.com/login", user: "UPPER")
        let source = [entry("same", url: "https://reading.example.com/", user: "UPPER"), entry("old", url: "http://reading.example.com/", user: "UPPER"), entry("same", url: "https://reading.example.com/", user: "upper")]
        let result = compare(source, [target])
        XCTAssertEqual(result.map(\.verdict), [.related, .related, .related])
        XCTAssertEqual(result.map { $0.matches.count }, [1, 1, 1])
        XCTAssertEqual(result[0].matches[0].password == source[0].password, true)
        XCTAssertEqual(result[1].matches[0].password == source[1].password, false)
        XCTAssertEqual(compare([entry("same", url: "https://reading.example.com", user: "another")], [target])[0].verdict, .new)
        XCTAssertEqual(compare([entry("same", url: "https://fake-reading.example.com", user: "UPPER")], [target])[0].verdict, .new)
        XCTAssertEqual(compare([entry("same", url: "https://other.reading.example.com", user: "UPPER")], [target])[0].verdict, .new)
        XCTAssertEqual(compare([target], [target])[0].verdict, .identical)
    }
    static func main() async throws {
        try testCSVPreservesSecretsAndQuotedNewlines()
        testMalformedOrUnknownFieldsStopImport()
        testConflictingTargetCannotBeClassifiedAsSafeEvenWithMatchingCopy()
        testAppleInternalConflictBlocksBothRows()
        testExactDuplicatesAndNotes()
        testConservativeIdentity()
        try testCLIUsingFakeExecutable()
        testLargeComparison()
        try await testBatchedReadingAndInterruption()
        try testJSONStreams()
        testRelatedURLsPreventDuplicateCreation()
        print("11 test groups passed (including related URL and username matching)")
    }
}
