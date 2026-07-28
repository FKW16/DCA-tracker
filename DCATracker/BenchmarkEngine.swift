import Foundation

struct HistoricalPrice: Codable, Equatable, Sendable { let date: Date; let close: Decimal }
struct BenchmarkCashFlow: Equatable, Sendable { let date: Date; let amount: Decimal; let portfolioFractionSold: Decimal }
struct ReturnPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let portfolioReturn: Decimal?
    let benchmarkReturn: Decimal
    var id: Date { date }
}
enum BenchmarkError: Error, Equatable { case noPricesBefore(Date), noCashFlows, invalidSaleFraction }

enum BenchmarkEngine {
    static func previousPrice(on date: Date, prices: [HistoricalPrice]) -> HistoricalPrice? {
        prices.filter { $0.date <= date }.max { $0.date < $1.date }
    }

    static func benchmarkShares(cashFlows: [BenchmarkCashFlow], prices: [HistoricalPrice]) -> Result<Decimal, BenchmarkError> {
        guard !cashFlows.isEmpty else { return .failure(.noCashFlows) }
        var shares = Decimal.zero
        for flow in cashFlows.sorted(by: { $0.date < $1.date }) {
            guard flow.portfolioFractionSold >= 0, flow.portfolioFractionSold <= 1 else { return .failure(.invalidSaleFraction) }
            guard let price = previousPrice(on: flow.date, prices: prices) else { return .failure(.noPricesBefore(flow.date)) }
            if flow.amount > 0 { shares += flow.amount / price.close }
            if flow.portfolioFractionSold > 0 { shares *= 1 - flow.portfolioFractionSold }
        }
        return .success(shares)
    }

    static func normalizedReturn(initialCost: Decimal, value: Decimal) -> Decimal? {
        guard initialCost > 0 else { return nil }; return value / initialCost - 1
    }

    static func returnCurve(cashFlows: [BenchmarkCashFlow], prices: [HistoricalPrice]) -> Result<[(Date, Decimal)], BenchmarkError> {
        guard !cashFlows.isEmpty else { return .failure(.noCashFlows) }
        let orderedFlows = cashFlows.sorted { $0.date < $1.date }, orderedPrices = prices.sorted { $0.date < $1.date }
        let firstDate = orderedFlows[0].date
        guard previousPrice(on: firstDate, prices: orderedPrices) != nil else { return .failure(.noPricesBefore(firstDate)) }
        var shares = Decimal.zero, basis = Decimal.zero, flowIndex = 0, points: [(Date, Decimal)] = []
        for price in orderedPrices where price.date >= firstDate {
            while flowIndex < orderedFlows.count, orderedFlows[flowIndex].date <= price.date {
                let flow = orderedFlows[flowIndex]
                guard flow.portfolioFractionSold >= 0, flow.portfolioFractionSold <= 1 else { return .failure(.invalidSaleFraction) }
                guard let executionPrice = previousPrice(on: flow.date, prices: orderedPrices) else { return .failure(.noPricesBefore(flow.date)) }
                if flow.amount > 0 { shares += flow.amount / executionPrice.close; basis += flow.amount }
                if flow.portfolioFractionSold > 0 { shares *= 1 - flow.portfolioFractionSold; basis *= 1 - flow.portfolioFractionSold }
                flowIndex += 1
            }
            if let value = normalizedReturn(initialCost: basis, value: shares * price.close) { points.append((price.date, value)) }
        }
        if !points.isEmpty { points[0].1 = 0 }
        return .success(points)
    }
}

enum BenchmarkDashboard {
    static func curve(purchases: [Purchase], sales: [Sale], spyPrices: [HistoricalPrice], currentPortfolioValue: Decimal, calendar: Calendar = .current) -> [ReturnPoint]? {
        guard !purchases.isEmpty, !spyPrices.isEmpty else { return nil }
        let invested = purchases.reduce(0) { $0 + $1.quantity * $1.price + $1.fee }
        var flows = purchases.map { BenchmarkCashFlow(date: $0.date, amount: $0.quantity * $0.price + $0.fee, portfolioFractionSold: 0) }
        flows += sales.map { sale in
            let heldBefore = purchases.filter { $0.date <= sale.date }.reduce(0) { $0 + $1.quantity } - sales.filter { $0.date < sale.date }.reduce(0) { $0 + $1.quantity }
            return BenchmarkCashFlow(date: sale.date, amount: 0, portfolioFractionSold: heldBefore > 0 ? min(sale.quantity / heldBefore, 1) : 0)
        }
        guard case .success(let dailyBenchmark) = BenchmarkEngine.returnCurve(cashFlows: flows, prices: spyPrices) else { return nil }
        var benchmark: [(Date, Decimal)] = []
        for point in dailyBenchmark {
            if let last = benchmark.last, calendar.isDate(last.0, equalTo: point.0, toGranularity: .month) {
                benchmark[benchmark.count - 1] = point
            } else {
                benchmark.append(point)
            }
        }
        let finalPortfolioReturn = invested > 0 ? currentPortfolioValue / invested - 1 : 0
        return benchmark.enumerated().map { index, point in
            let portfolioReturn: Decimal? = index == 0 ? 0 : (index == benchmark.count - 1 ? finalPortfolioReturn : nil)
            return .init(date: point.0, portfolioReturn: portfolioReturn, benchmarkReturn: point.1)
        }
    }
}
