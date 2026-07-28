import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MarketQuote: Codable, Equatable, Sendable {
    let symbol: String; let price: Decimal; let previousClose: Decimal?; let timestamp: Date
}
enum QuoteError: Error, Equatable, LocalizedError {
    case missingAPIKey, invalidResponse, rateLimited, decoding, invalidPrice, provider(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "缺少 API Key"
        case .invalidResponse: "服务器响应无效"
        case .httpStatus(let code): "HTTP 错误 \(code)"
        case .rateLimited: "API 请求频率已达上限（429）"
        case .decoding: "无法解析行情响应"
        case .invalidPrice: "响应中没有有效价格"
        case .provider(let message): "Twelve Data：\(message)"
        }
    }
}
protocol QuoteDataSource: Sendable { func quote(symbol: String, apiKey: String) async throws -> MarketQuote }
protocol HistoricalQuoteDataSource: Sendable {
    func history(symbol: String, startDate: Date?, apiKey: String) async throws -> [HistoricalPrice]
}

final class TwelveDataSource: QuoteDataSource, HistoricalQuoteDataSource, @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func quote(symbol: String, apiKey: String) async throws -> MarketQuote {
        guard !apiKey.isEmpty else { throw QuoteError.missingAPIKey }
        var components = URLComponents(string: "https://api.twelvedata.com/quote")!
        components.queryItems = [.init(name: "symbol", value: symbol), .init(name: "apikey", value: apiKey)]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuoteError.invalidResponse }
        if http.statusCode == 429 { throw QuoteError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw QuoteError.httpStatus(http.statusCode) }
        struct Payload: Decodable { let symbol: String?; let close: String?; let previous_close: String?; let status: String?; let message: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw QuoteError.decoding }
        if payload.status == "error" { throw QuoteError.provider(payload.message ?? "未知错误") }
        guard let text = payload.close, let price = Decimal(string: text), price > 0 else { throw QuoteError.invalidPrice }
        return .init(symbol: payload.symbol ?? symbol, price: price,
                     previousClose: payload.previous_close.flatMap { Decimal(string: $0) }, timestamp: Date())
    }

    func history(symbol: String, startDate: Date? = nil, apiKey: String) async throws -> [HistoricalPrice] {
        guard !apiKey.isEmpty else { throw QuoteError.missingAPIKey }
        var components = URLComponents(string: "https://api.twelvedata.com/time_series")!
        var items = [URLQueryItem(name: "symbol", value: symbol), .init(name: "interval", value: "1day"),
                     .init(name: "outputsize", value: "5000"), .init(name: "apikey", value: apiKey)]
        if let startDate { items.append(.init(name: "start_date", value: Self.dayFormatter.string(from: startDate))) }
        components.queryItems = items
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse else { throw QuoteError.invalidResponse }
        if http.statusCode == 429 { throw QuoteError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw QuoteError.httpStatus(http.statusCode) }
        struct Value: Decodable { let datetime: String; let close: String }
        struct Payload: Decodable { let values: [Value]?; let status: String?; let message: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw QuoteError.decoding }
        if payload.status == "error" { throw QuoteError.provider(payload.message ?? "未知错误") }
        guard let values = payload.values else { throw QuoteError.decoding }
        let decoded = values.compactMap { value -> HistoricalPrice? in
            guard let date = Self.dayFormatter.date(from: value.datetime), let close = Decimal(string: value.close), close > 0 else { return nil }
            return .init(date: date, close: close)
        }.sorted { $0.date < $1.date }
        guard !decoded.isEmpty else { throw QuoteError.invalidPrice }; return decoded
    }

    private static let dayFormatter: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.calendar = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0); value.dateFormat = "yyyy-MM-dd"; return value }()
}

struct HistoricalQuoteCache: Sendable {
    let directory: URL
    init(directory: URL? = nil) throws {
        if let directory { self.directory = directory } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.directory = support.appendingPathComponent("DCA Tracker/QuoteCache", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func load(symbol: String) -> [HistoricalPrice] {
        guard let data = try? Data(contentsOf: url(symbol)), let values = try? JSONDecoder().decode([HistoricalPrice].self, from: data) else { return [] }
        return values
    }
    func save(_ values: [HistoricalPrice], symbol: String) throws { try JSONEncoder().encode(values).write(to: url(symbol), options: .atomic) }
    func merged(_ old: [HistoricalPrice], _ fresh: [HistoricalPrice]) -> [HistoricalPrice] {
        Dictionary((old + fresh).map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.date < $1.date }
    }
    private func url(_ symbol: String) -> URL { directory.appendingPathComponent(symbol.uppercased() + "-daily.json") }
}

struct HistoricalQuoteService: Sendable {
    let source: any HistoricalQuoteDataSource; let cache: HistoricalQuoteCache
    func refresh(symbol: String, apiKey: String) async -> (prices: [HistoricalPrice], usedCache: Bool, error: String?) {
        let cached = cache.load(symbol: symbol)
        let start = cached.last.map { Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: $0.date)! }
        do {
            let fresh = try await source.history(symbol: symbol, startDate: start, apiKey: apiKey)
            let values = cache.merged(cached, fresh); try cache.save(values, symbol: symbol)
            return (values, false, nil)
        } catch { return (cached, true, error.localizedDescription) }
    }
}

actor QuoteCoordinator {
    private let source: any QuoteDataSource
    private var inFlight: [String: Task<MarketQuote, Error>] = [:]
    init(source: any QuoteDataSource) { self.source = source }
    func quote(symbol: String, apiKey: String) async throws -> MarketQuote {
        if let task = inFlight[symbol] { return try await task.value }
        let task = Task { try await source.quote(symbol: symbol, apiKey: apiKey) }
        inFlight[symbol] = task
        defer { inFlight[symbol] = nil }
        return try await task.value
    }
}

enum EffectiveQuote: Equatable { case live(MarketQuote), cache(MarketQuote), manual(Decimal), unavailable }
enum QuoteFallback {
    static func resolve(live: Result<MarketQuote, Error>, cached: MarketQuote?, manual: Decimal?) -> EffectiveQuote {
        if case .success(let quote) = live { return .live(quote) }
        if let cached { return .cache(cached) }
        if let manual, manual > 0 { return .manual(manual) }
        return .unavailable
    }
}
