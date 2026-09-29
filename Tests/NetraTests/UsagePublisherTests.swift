import os
import XCTest
@testable import Netra

/// Answers every request with a scripted response; records what was sent.
final class PublishStubProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var body: Data = Data()
        var networkError: URLError.Code?
    }

    struct Seen: Sendable {
        var url: URL?
        var method: String?
        var authorization: String?
        var contentType: String?
        var body: Data
    }

    private static let storage = OSAllocatedUnfairLock<(replies: [Reply], seen: [Seen])>(initialState: ([], []))

    static func script(_ replies: [Reply]) {
        storage.withLock { $0 = (replies, []) }
    }

    static var seen: [Seen] { storage.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // httpBody is moved into a stream by the time a protocol sees it.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let seen = Seen(
            url: request.url, method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: body
        )
        let reply = Self.storage.withLock { state -> Reply in
            state.seen.append(seen)
            return state.replies.isEmpty ? Reply(status: 204) : state.replies.removeFirst()
        }
        if let code = reply.networkError {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A settable test clock.
final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_790_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

final class UsagePublisherTests: XCTestCase {
    private let endpoint = URL(string: "https://example.test/api/usage")!
    private let token = "test-token-not-a-secret"
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        reset()
    }

    /// Fresh defaults, clock, and stub script (also between table rows).
    private func reset() {
        if defaults != nil { defaults.removePersistentDomain(forName: suiteName) }
        suiteName = "NetraTests.UsagePublisher.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        clock = TestClock()
        PublishStubProtocol.script([])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makePublisher(version: String = "1.0.0", token: String? = "test-token-not-a-secret") -> UsagePublisher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublishStubProtocol.self]
        let clock = clock!
        return UsagePublisher(
            session: URLSession(configuration: configuration),
            defaults: UserDefaults(suiteName: suiteName)!, version: version,
            now: { clock.now },
            tokenProvider: { _ in token }
        )
    }

    private func feed(output: Int = 5, generatedAt: String = "2026-09-29T00:00:00Z") -> UsageFeed {
        let figures = UsageFeed.Figures(input: 1, output: output, cacheRead: 0, cacheWrite: 0, cost: 0.01)
        return UsageFeed(
            schema: UsageFeed.schemaID, generatedAt: generatedAt, source: "netra test", timeZone: "UTC",
            daily: [UsageFeed.Day(date: "2026-09-29", agents: [
                "claude": UsageFeed.Agent(figures, models: ["test-model": figures]),
            ])]
        )
    }

    // MARK: Request and status rows

    func testPostsTheFeedWithBearerTokenAndJSON() async throws {
        let publisher = makePublisher()
        let outcome = await publisher.publish(feed(), to: endpoint)
        XCTAssertEqual(outcome, .published)
        let request = try XCTUnwrap(PublishStubProtocol.seen.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.authorization, "Bearer \(token)")
        XCTAssertEqual(request.contentType, "application/json")
        XCTAssertEqual(request.body, try feed().encoded())
        let state = await publisher.state
        XCTAssertEqual(state.lastSuccessAt, clock.now)
        XCTAssertNil(state.lastError)
    }

    func testSuccessRowsRecordSuccess() async {
        for reply in [
            PublishStubProtocol.Reply(status: 204),
            PublishStubProtocol.Reply(status: 200, body: Data(#"{"status":"unchanged"}"#.utf8)),
            PublishStubProtocol.Reply(status: 409),
        ] {
            reset()
            PublishStubProtocol.script([reply])
            let publisher = makePublisher()
            let outcome = await publisher.publish(feed(), to: endpoint)
            XCTAssertEqual(outcome, .published, "status \(reply.status)")
            let state = await publisher.state
            XCTAssertEqual(state.lastContentHash, feed().contentHash())
            XCTAssertFalse(state.isStopped)
        }
    }

    func testUnauthorizedStopsUntilSettingsChange() async {
        PublishStubProtocol.script([.init(status: 401)])
        let publisher = makePublisher()
        guard case .stopped = await publisher.publish(feed(), to: endpoint) else {
            return XCTFail("401 should stop publishing")
        }
        clock.advance(24 * 3600)
        let skipped = await publisher.publish(feed(output: 9), to: endpoint)
        XCTAssertEqual(skipped, .skipped(.stopped))
        XCTAssertEqual(PublishStubProtocol.seen.count, 1)
        let message = await publisher.state.lastError
        XCTAssertTrue(message?.contains("401") == true)
        XCTAssertFalse(message?.contains(token) == true, "the token is never shown")

        await publisher.settingsChanged()
        let resumed = await publisher.publish(feed(output: 9), to: endpoint)
        XCTAssertEqual(resumed, .published)
    }

    func testRejectedFeedStopsUntilSettingsOrVersionChange() async {
        for status in [413, 422] {
            reset()
            PublishStubProtocol.script([.init(status: status, body: Data(#"{"error":"daily[0].date is invalid"}"#.utf8))])
            let publisher = makePublisher(version: "1.0.0")
            let outcome = await publisher.publish(feed(), to: endpoint)
            guard case .stopped(let message) = outcome else {
                XCTFail("\(status) should stop publishing")
                continue
            }
            XCTAssertTrue(message.contains("\(status)"))
            XCTAssertTrue(message.contains("daily[0].date is invalid"), "shows the site's explanation")
            clock.advance(3 * 3600)
            let stillStopped = await publisher.publish(feed(), to: endpoint)
            XCTAssertEqual(stillStopped, .skipped(.stopped))

            // Persisted: a relaunch of the same version stays stopped…
            let relaunched = makePublisher(version: "1.0.0")
            let relaunchedOutcome = await relaunched.publish(feed(), to: endpoint)
            XCTAssertEqual(relaunchedOutcome, .skipped(.stopped))
            // …and the next Netra version tries again.
            let upgraded = makePublisher(version: "1.0.1")
            let upgradedOutcome = await upgraded.publish(feed(), to: endpoint)
            XCTAssertEqual(upgradedOutcome, .published)
        }
    }

    func testFeedsOverTwoMegabytesAreNeverSent() async {
        let figures = UsageFeed.Figures(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0)
        let models = Dictionary(uniqueKeysWithValues: (0..<40_000).map { ("test-model-\($0)", figures) })
        let big = UsageFeed(schema: UsageFeed.schemaID, generatedAt: "2026-09-29T00:00:00Z", source: "netra test",
                            timeZone: "UTC", daily: [.init(date: "2026-09-29", agents: ["claude": .init(figures, models: models)])])
        let publisher = makePublisher()
        guard case .stopped = await publisher.publish(big, to: endpoint) else {
            return XCTFail("an oversized feed should stop publishing")
        }
        XCTAssertTrue(PublishStubProtocol.seen.isEmpty)
    }

    // MARK: Throttling

    func testPublishesAtMostOnceEveryFiveMinutes() async {
        let publisher = makePublisher()
        let first = await publisher.publish(feed(output: 1), to: endpoint)
        XCTAssertEqual(first, .published)
        clock.advance(4 * 60 + 59)
        let early = await publisher.publish(feed(output: 2), to: endpoint)
        XCTAssertEqual(early, .skipped(.tooSoon))
        clock.advance(1)
        let onTime = await publisher.publish(feed(output: 2), to: endpoint)
        XCTAssertEqual(onTime, .published)
        XCTAssertEqual(PublishStubProtocol.seen.count, 2)
    }

    func testSkipsUnchangedContentUntilTheHourlyHeartbeat() async {
        let publisher = makePublisher()
        let first = await publisher.publish(feed(generatedAt: "2026-09-29T00:00:00Z"), to: endpoint)
        XCTAssertEqual(first, .published)
        clock.advance(10 * 60)
        // Only generatedAt differs: not worth a POST.
        let same = await publisher.publish(feed(generatedAt: "2026-09-29T00:10:00Z"), to: endpoint)
        XCTAssertEqual(same, .skipped(.unchanged))
        clock.advance(50 * 60 - 1)
        let stillSame = await publisher.publish(feed(generatedAt: "2026-09-29T00:59:59Z"), to: endpoint)
        XCTAssertEqual(stillSame, .skipped(.unchanged))
        clock.advance(1)
        let heartbeat = await publisher.publish(feed(generatedAt: "2026-09-29T01:00:00Z"), to: endpoint)
        XCTAssertEqual(heartbeat, .published)
        XCTAssertEqual(PublishStubProtocol.seen.count, 2)
    }

    func testChangedContentPublishesAfterTheInterval() async {
        let publisher = makePublisher()
        _ = await publisher.publish(feed(output: 1), to: endpoint)
        clock.advance(5 * 60)
        let changed = await publisher.publish(feed(output: 2), to: endpoint)
        XCTAssertEqual(changed, .published)
    }

    func testTransientFailuresBackOffDoublingToThirtyMinutes() async {
        let transient: [PublishStubProtocol.Reply] = [
            .init(status: 503), .init(status: 429), .init(status: 0, networkError: .notConnectedToInternet),
            .init(status: 500), .init(status: 502), .init(status: 504), .init(status: 500), .init(status: 500),
        ]
        PublishStubProtocol.script(transient)
        let publisher = makePublisher()
        var delays: [TimeInterval] = []
        for _ in transient {
            let start = clock.now
            guard case .failed = await publisher.publish(feed(), to: endpoint) else {
                return XCTFail("transient statuses should back off")
            }
            let next = await publisher.state.nextRetryAt!
            let delay = next.timeIntervalSince(start)
            delays.append(delay)
            clock.advance(delay - 1)
            let waiting = await publisher.publish(feed(), to: endpoint)
            XCTAssertEqual(waiting, .skipped(.backingOff))
            clock.advance(1)
        }
        XCTAssertEqual(delays, [30, 60, 120, 240, 480, 960, 1800, 1800])
        XCTAssertEqual(PublishStubProtocol.seen.count, transient.count)

        // Success resets the backoff.
        let recovered = await publisher.publish(feed(), to: endpoint)
        XCTAssertEqual(recovered, .published)
        let state = await publisher.state
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertNil(state.nextRetryAt)
        XCTAssertNil(state.lastError)
    }

    func testPublishNowBypassesThrottleHashAndBackoff() async {
        PublishStubProtocol.script([.init(status: 204), .init(status: 503), .init(status: 204)])
        let publisher = makePublisher()
        _ = await publisher.publish(feed(), to: endpoint)
        let throttled = await publisher.publish(feed(), to: endpoint)
        XCTAssertEqual(throttled, .skipped(.tooSoon))
        guard case .failed = await publisher.publish(feed(), to: endpoint, force: true) else {
            return XCTFail("forced publish should POST")
        }
        let forced = await publisher.publish(feed(), to: endpoint, force: true)
        XCTAssertEqual(forced, .published)
        XCTAssertEqual(PublishStubProtocol.seen.count, 3)
    }

    // MARK: Configuration

    func testMissingEndpointOrTokenNeverPosts() async {
        let publisher = makePublisher(token: nil)
        let noEndpoint = await publisher.publish(feed(), to: nil)
        XCTAssertEqual(noEndpoint, .skipped(.notConfigured))
        let noToken = await publisher.publish(feed(), to: endpoint)
        XCTAssertEqual(noToken, .skipped(.noToken))
        XCTAssertTrue(PublishStubProtocol.seen.isEmpty)
    }

    func testTokenIsNeverPersistedInDefaults() async {
        let publisher = makePublisher()
        _ = await publisher.publish(feed(), to: endpoint)
        let everything = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(everything.isEmpty)
        for value in everything.values {
            let text = (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
            XCTAssertFalse(text.contains(token))
        }
    }

    func testEndpointMustBeHTTPSExceptLocalhost() {
        XCTAssertNotNil(UsagePublishEndpoint.validated("https://www.example.test/api/usage"))
        XCTAssertNotNil(UsagePublishEndpoint.validated("  http://localhost:3000/api/usage "))
        XCTAssertNotNil(UsagePublishEndpoint.validated("http://127.0.0.1:3000/api/usage"))
        XCTAssertNil(UsagePublishEndpoint.validated("http://www.example.test/api/usage"))
        XCTAssertNil(UsagePublishEndpoint.validated("http://localhost.example.test/api/usage"))
        XCTAssertNil(UsagePublishEndpoint.validated("ftp://example.test/usage"))
        XCTAssertNil(UsagePublishEndpoint.validated("example.test/api/usage"))
        XCTAssertNil(UsagePublishEndpoint.validated(""))
    }
}
