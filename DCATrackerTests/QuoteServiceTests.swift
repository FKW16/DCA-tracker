import XCTest
@testable import DCATracker

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (response, data) = try Self.handler(request); client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class QuoteServiceTests: XCTestCase {
    private func source(status: Int = 200, body: String) -> TwelveDataSource {
        StubURLProtocol.handler = { request in (.init(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8)) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return TwelveDataSource(session: URLSession(configuration: config))
    }
    func testTwelveDataSuccess() async throws {
        let quote = try await source(body: #"{"symbol":"VTI","close":"250.12","previous_close":"249.00"}"#).quote(symbol: "VTI", apiKey: "secret")
        XCTAssertEqual(quote.price, Decimal(string: "250.12")); XCTAssertEqual(quote.previousClose, 249)
    }
    func testTwelveDataHTTPFailure() async { do { _ = try await source(status: 500, body: "{}").quote(symbol: "VTI", apiKey: "x"); XCTFail() } catch { XCTAssertEqual(error as? QuoteError, .httpStatus(500)) } }
    func testTwelveDataRateLimit() async { do { _ = try await source(status: 429, body: "{}").quote(symbol: "VTI", apiKey: "x"); XCTFail() } catch { XCTAssertEqual(error as? QuoteError, .rateLimited) } }
    func testTwelveDataDecodeFailure() async { do { _ = try await source(body: "bad").quote(symbol: "VTI", apiKey: "x"); XCTFail() } catch { XCTAssertEqual(error as? QuoteError, .decoding) } }
    func testTwelveDataInvalidPrice() async { do { _ = try await source(body: #"{"close":"0"}"#).quote(symbol: "VTI", apiKey: "x"); XCTFail() } catch { XCTAssertEqual(error as? QuoteError, .invalidPrice) } }
    func testTwelveDataProviderErrorIncludesMessage() async {
        do { _ = try await source(body: #"{"status":"error","message":"Invalid API key"}"#).quote(symbol: "VTI", apiKey: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? QuoteError, .provider("Invalid API key")) }
    }
    func testFallbackUsesCacheBeforeManual() {
        let cached = MarketQuote(symbol: "VTI", price: 10, previousClose: 9, timestamp: Date())
        XCTAssertEqual(QuoteFallback.resolve(live: .failure(QuoteError.rateLimited), cached: cached, manual: 8), .cache(cached))
    }
    func testFallbackUsesManualWithoutCache() { XCTAssertEqual(QuoteFallback.resolve(live: .failure(QuoteError.rateLimited), cached: nil, manual: 8), .manual(8)) }
    func testConcurrentRequestsAreMerged() async throws {
        actor CounterSource: QuoteDataSource { var count = 0; func quote(symbol: String, apiKey: String) async throws -> MarketQuote { count += 1; try await Task.sleep(for: .milliseconds(50)); return .init(symbol: symbol, price: 1, previousClose: nil, timestamp: Date()) } }
        let source = CounterSource(), coordinator = QuoteCoordinator(source: source)
        async let first = coordinator.quote(symbol: "VTI", apiKey: "x"); async let second = coordinator.quote(symbol: "VTI", apiKey: "x")
        _ = try await (first, second); let count = await source.count; XCTAssertEqual(count, 1)
    }
    func testHistoricalDailyResponseDecodesAndSorts() async throws {
        let source = source(body: #"{"values":[{"datetime":"2025-01-03","close":"101.5"},{"datetime":"2025-01-02","close":"100"}]}"#)
        let values = try await source.history(symbol: "SPY", startDate: nil, apiKey: "x")
        XCTAssertEqual(values.map(\.close), [100, Decimal(string: "101.5")!])
    }
    func testHistoricalRequestUsesIncrementalStartDate() async throws {
        nonisolated(unsafe) var requestedURL: URL?
        StubURLProtocol.handler = { request in requestedURL = request.url; return (.init(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"values":[{"datetime":"2025-01-04","close":"102"}]}"#.utf8)) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        var utcCalendar = Calendar(identifier: .gregorian); utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try await TwelveDataSource(session: URLSession(configuration: config)).history(symbol: "SPY", startDate: utcCalendar.date(from: .init(year: 2025, month: 1, day: 4)), apiKey: "x")
        let startDate = requestedURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "start_date" }?.value
        XCTAssertEqual(startDate, "2025-01-04")
    }
    func testHistoricalFailureFallsBackToCache() async throws {
        struct Failing: HistoricalQuoteDataSource { func history(symbol: String, startDate: Date?, apiKey: String) async throws -> [HistoricalPrice] { throw QuoteError.rateLimited } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try HistoricalQuoteCache(directory: directory), expected = [HistoricalPrice(date: Date(timeIntervalSince1970: 0), close: 100)]
        try cache.save(expected, symbol: "SPY")
        let result = await HistoricalQuoteService(source: Failing(), cache: cache).refresh(symbol: "SPY", apiKey: "x")
        XCTAssertEqual(result.prices, expected); XCTAssertTrue(result.usedCache); XCTAssertNotNil(result.error)
    }
}
