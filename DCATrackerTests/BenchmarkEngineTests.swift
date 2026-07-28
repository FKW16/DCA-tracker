import XCTest
@testable import DCATracker

final class BenchmarkEngineTests: XCTestCase {
    private func day(_ value: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(value * 86_400)) }
    func testWeekendUsesPreviousTradingDay() {
        let friday = HistoricalPrice(date: day(1), close: 100)
        XCTAssertEqual(BenchmarkEngine.previousPrice(on: day(3), prices: [friday]), friday)
    }
    func testNoEarlierPriceIsExplicitFailure() {
        let result = BenchmarkEngine.benchmarkShares(cashFlows: [.init(date: day(1), amount: 100, portfolioFractionSold: 0)], prices: [.init(date: day(2), close: 10)])
        XCTAssertEqual(result, .failure(.noPricesBefore(day(1))))
    }
    func testSameCashFlowBuysBenchmarkShares() {
        let result = BenchmarkEngine.benchmarkShares(cashFlows: [.init(date: day(1), amount: 100, portfolioFractionSold: 0), .init(date: day(2), amount: 50, portfolioFractionSold: 0)], prices: [.init(date: day(1), close: 10), .init(date: day(2), close: 10)])
        XCTAssertEqual(try? result.get(), 15)
    }
    func testSaleUsesPortfolioFraction() {
        let result = BenchmarkEngine.benchmarkShares(cashFlows: [.init(date: day(1), amount: 100, portfolioFractionSold: 0), .init(date: day(2), amount: 0, portfolioFractionSold: Decimal(string: "0.25")!)], prices: [.init(date: day(1), close: 10), .init(date: day(2), close: 12)])
        XCTAssertEqual(try? result.get(), Decimal(string: "7.5"))
    }
    func testBenchmarkCurveNormalizesFirstCashFlowToZero() throws {
        let values = try BenchmarkEngine.returnCurve(cashFlows: [.init(date: day(1), amount: 100, portfolioFractionSold: 0)], prices: [.init(date: day(1), close: 10), .init(date: day(2), close: 11)]).get()
        XCTAssertEqual(values.map(\.1), [0, Decimal(string: "0.1")!])
    }
    func testBenchmarkCurveAppliesLaterCashFlowAtHistoricalPrice() throws {
        let values = try BenchmarkEngine.returnCurve(cashFlows: [.init(date: day(1), amount: 100, portfolioFractionSold: 0), .init(date: day(2), amount: 110, portfolioFractionSold: 0)], prices: [.init(date: day(1), close: 10), .init(date: day(2), close: 11)]).get()
        XCTAssertEqual(values.last?.1, Decimal(10) / Decimal(210))
    }
    func testDashboardDoesNotFabricateIntermediatePortfolioReturns() throws {
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI")
        let calendar = Calendar(identifier: .gregorian)
        let dates = [1, 2, 3].map { calendar.date(from: DateComponents(year: 2025, month: $0, day: 1))! }
        let purchase = Purchase(date: dates[0], quantity: 10, price: 10, account: account, investment: investment)
        let points = try XCTUnwrap(BenchmarkDashboard.curve(
            purchases: [purchase], sales: [],
            spyPrices: [.init(date: dates[0], close: 10), .init(date: dates[1], close: 11), .init(date: dates[2], close: 12)],
            currentPortfolioValue: 120, calendar: calendar))
        XCTAssertEqual(points.map(\.portfolioReturn), [0, nil, Decimal(string: "0.2")!])
    }
    func testDashboardCurveUsesLastBenchmarkPointInEachMonth() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date: (Int, Int) -> Date = { month, day in calendar.date(from: DateComponents(year: 2025, month: month, day: day))! }
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI")
        let purchase = Purchase(date: date(1, 1), quantity: 10, price: 10, account: account, investment: investment)
        let points = try XCTUnwrap(BenchmarkDashboard.curve(
            purchases: [purchase], sales: [],
            spyPrices: [.init(date: date(1, 1), close: 10), .init(date: date(1, 31), close: 11), .init(date: date(2, 28), close: 12)],
            currentPortfolioValue: 120, calendar: calendar))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.benchmarkReturn), [Decimal(string: "0.1")!, Decimal(string: "0.2")!])
    }
}
