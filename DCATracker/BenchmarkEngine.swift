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

    /// 组合真实历史收益曲线:按月用各标的历史收盘价合成组合市值(不伪造行情)。
    /// 缺历史行情的标的按投入成本计入(该部分收益为 0),并通过 missingSymbols 提示。
    /// 末点用当前真实市值 + 累计卖出回款校准,口径:收益 =(市值+回款)÷投入−1。
    static func curveWithPortfolio(purchases: [Purchase], sales: [Sale], spyPrices: [HistoricalPrice], portfolioPrices: [String: [HistoricalPrice]], currentPortfolioValue: Decimal, calendar: Calendar = .current) -> (points: [ReturnPoint], missingSymbols: [String])? {
        guard !purchases.isEmpty, !spyPrices.isEmpty else { return nil }
        // 基准月度点(份额法,与原逻辑一致)
        let invested = purchases.reduce(0) { $0 + $1.quantity * $1.price + $1.fee }
        var flows = purchases.map { BenchmarkCashFlow(date: $0.date, amount: $0.quantity * $0.price + $0.fee, portfolioFractionSold: 0) }
        flows += sales.map { sale in
            let heldBefore = purchases.filter { $0.date <= sale.date }.reduce(0) { $0 + $1.quantity } - sales.filter { $0.date < sale.date }.reduce(0) { $0 + $1.quantity }
            return BenchmarkCashFlow(date: sale.date, amount: 0, portfolioFractionSold: heldBefore > 0 ? min(sale.quantity / heldBefore, 1) : 0)
        }
        guard case .success(let dailyBenchmark) = BenchmarkEngine.returnCurve(cashFlows: flows, prices: spyPrices) else { return nil }
        var benchmark: [(Date, Decimal)] = []
        for point in dailyBenchmark {
            if let last = benchmark.last, calendar.isDate(last.0, equalTo: point.0, toGranularity: .month) { benchmark[benchmark.count - 1] = point } else { benchmark.append(point) }
        }
        // 组合月度真实收益:各标的按历史收盘价估值
        var missing: [String] = []
        let buyByKey = Dictionary(grouping: purchases) { $0.investment?.symbol ?? "" }
        let saleByKey = Dictionary(grouping: sales) { $0.investment?.symbol ?? "" }
        var points: [ReturnPoint] = []
        for anchor in benchmark {
            let date = anchor.0
            var value = Decimal.zero, soldCash = Decimal.zero, investedAt = Decimal.zero
            for symbol in buyByKey.keys {
                let buys = (buyByKey[symbol] ?? []).filter { $0.date <= date }
                let sells = (saleByKey[symbol] ?? []).filter { $0.date <= date }
                let shares = buys.reduce(Decimal.zero) { $0 + $1.quantity } - sells.reduce(Decimal.zero) { $0 + $1.quantity }
                let cost = buys.reduce(Decimal.zero) { $0 + $1.quantity * $1.price + $1.fee }
                soldCash += sells.reduce(Decimal.zero) { $0 + $1.quantity * $1.price - $1.fee }
                investedAt += cost
                var contribution: Decimal?
                if let prices = portfolioPrices[symbol], let first = prices.first, date >= first.date, let price = BenchmarkEngine.previousPrice(on: date, prices: prices)?.close {
                    contribution = shares * price
                }
                value += contribution ?? cost
                if contribution == nil, cost > 0, !missing.contains(symbol) { missing.append(symbol) }
            }
            guard investedAt > 0 else { continue }
            points.append(.init(date: date, portfolioReturn: (value + soldCash) / investedAt - 1, benchmarkReturn: anchor.1))
        }
        // 末点用当前真实市值校准
        if invested > 0, let last = points.last {
            let soldCashNow = sales.reduce(Decimal.zero) { $0 + $1.quantity * $1.price - $1.fee }
            points[points.count - 1] = .init(date: last.date, portfolioReturn: (currentPortfolioValue + soldCashNow) / invested - 1, benchmarkReturn: last.benchmarkReturn)
        }
        return (points, missing)
    }
}
