import XCTest
@testable import DCATracker

final class DashboardAnalyticsTests: XCTestCase {
    private let account = BrokerageAccount(name: "A")
    private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar(identifier: .gregorian).date(from: .init(year: year, month: month, day: day))!
    }

    func testHoldingsUseNetQuantityMarketValueAndWeight() {
        let vti = Investment(symbol: "VTI", name: "VTI"); vti.latestPrice = 10
        let vxus = Investment(symbol: "VXUS", name: "VXUS"); vxus.manualPrice = 20
        let buys = [Purchase(date: date(2025, 1), quantity: 10, price: 8, account: account, investment: vti),
                    Purchase(date: date(2025, 1), quantity: 5, price: 18, account: account, investment: vxus)]
        let sells = [Sale(date: date(2025, 2), quantity: 2, price: 12, account: account, investment: vti)]
        let value = DashboardAnalytics.snapshot(investments: [vti, vxus], purchases: buys, sales: sells)
        XCTAssertEqual(value.holdings.map(\.marketValue), [80, 100])
        XCTAssertEqual(value.holdings[0].quantity, 8)
        XCTAssertEqual(value.holdings[0].weight, Decimal(4) / Decimal(9))
    }

    func testMissingPriceHoldingIsExcludedAndReported() {
        let item = Investment(symbol: "QQQ", name: "QQQ")
        let buy = Purchase(date: date(2025, 1), quantity: 1, price: 100, account: account, investment: item)
        let value = DashboardAnalytics.snapshot(investments: [item], purchases: [buy], sales: [])
        XCTAssertTrue(value.holdings.isEmpty); XCTAssertEqual(value.missingPriceSymbols, ["QQQ"])
    }

    func testMonthlyContributionsAggregateAcrossYearsAndIncludeFees() {
        let item = Investment(symbol: "VTI", name: "VTI")
        let buys = [Purchase(date: date(2024, 12, 1), quantity: 2, price: 10, fee: 1, account: account, investment: item),
                    Purchase(date: date(2024, 12, 20), quantity: 1, price: 10, fee: 2, account: account, investment: item),
                    Purchase(date: date(2025, 1), quantity: 3, price: 10, fee: 3, account: account, investment: item)]
        let value = DashboardAnalytics.snapshot(investments: [item], purchases: buys, sales: [], calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(value.monthlyContributions.map(\.amount), [33, 33])
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: value.monthlyContributions[0].month), 2024)
    }

    func testAccountHoldingsAggregateNetMarketValueAndWeight() {
        let secondAccount = BrokerageAccount(name: "B")
        let vti = Investment(symbol: "VTI", name: "VTI"); vti.latestPrice = 10
        let vxus = Investment(symbol: "VXUS", name: "VXUS"); vxus.manualPrice = 20
        let buys = [Purchase(date: date(2025, 1), quantity: 10, price: 8, account: account, investment: vti),
                    Purchase(date: date(2025, 1), quantity: 5, price: 18, account: secondAccount, investment: vxus)]
        let sells = [Sale(date: date(2025, 2), quantity: 2, price: 12, account: account, investment: vti)]

        let value = DashboardAnalytics.snapshot(investments: [vti, vxus], purchases: buys, sales: sells)

        XCTAssertEqual(value.accountHoldings.map(\.accountName), ["A", "B"])
        XCTAssertEqual(value.accountHoldings.map(\.marketValue), [80, 100])
        XCTAssertEqual(value.accountHoldings[0].weight, Decimal(4) / Decimal(9))
    }

    func testUSDFormatUsesTrailingDollarAndGrouping() {
        XCTAssertEqual(USDFormat.string(Decimal(string: "1234.5")!), "1,234.50 $")
    }
}
