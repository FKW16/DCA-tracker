import XCTest
@testable import DCATracker

final class PositionReportTests: XCTestCase {
    private let account = BrokerageAccount(name: "A")
    private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar(identifier: .gregorian).date(from: .init(year: year, month: month, day: day))!
    }

    func testAverageCostUsesRemainingBasisAfterSaleThenBuy() {
        let vti = Investment(symbol: "VTI", name: "VTI")
        vti.latestPrice = 18
        let buys = [
            Purchase(date: date(2025, 1), quantity: 10, price: 10, account: account, investment: vti),
            Purchase(date: date(2025, 3), quantity: 5, price: 20, account: account, investment: vti)
        ]
        let sells = [Sale(date: date(2025, 2), quantity: 5, price: 12, account: account, investment: vti)]

        let row = PositionReportService.holdings(investments: [vti], purchases: buys, sales: sells)[0]

        XCTAssertEqual(row.quantity, 10)
        XCTAssertEqual(row.totalCost, 150)
        XCTAssertEqual(row.averageCost, 15)
        XCTAssertEqual(row.marketValue, 180)
        XCTAssertEqual(row.unrealizedPL, 30)
    }

    func testFeesStayInCostAndAccountsAggregate() {
        let other = BrokerageAccount(name: "B")
        let vti = Investment(symbol: "VTI", name: "VTI")
        vti.manualPrice = 12
        let buys = [
            Purchase(date: date(2025, 1), quantity: 10, price: 10, fee: 2, account: account, investment: vti),
            Purchase(date: date(2025, 1, 2), quantity: 4, price: 10, account: other, investment: vti)
        ]

        let row = PositionReportService.holdings(investments: [vti], purchases: buys, sales: [])[0]

        XCTAssertEqual(row.quantity, 14)
        XCTAssertEqual(row.totalCost, 142)
        XCTAssertEqual(row.currentPrice, 12)
        XCTAssertTrue(row.hasValidPrice)
    }

    func testClosedPositionIsOmittedAndMissingPriceIsNotTreatedAsZeroValue() {
        let soldOut = Investment(symbol: "QQQ", name: "QQQ")
        soldOut.latestPrice = 10
        let missing = Investment(symbol: "VXUS", name: "VXUS")
        let buys = [
            Purchase(date: date(2025, 1), quantity: 2, price: 10, account: account, investment: soldOut),
            Purchase(date: date(2025, 1), quantity: 3, price: 20, account: account, investment: missing)
        ]
        let sells = [Sale(date: date(2025, 2), quantity: 2, price: 11, account: account, investment: soldOut)]

        let rows = PositionReportService.holdings(investments: [soldOut, missing], purchases: buys, sales: sells)

        XCTAssertEqual(rows.map(\.symbol), ["VXUS"])
        XCTAssertFalse(rows[0].hasValidPrice)
        XCTAssertEqual(rows[0].marketValue, 0)
        XCTAssertEqual(rows[0].totalCost, 60)
        XCTAssertEqual(rows[0].unrealizedPL, 0)
        let report = PositionReportService.markdown(holdings: rows, positionCost: 0, marketValue: 0, missingSymbols: ["VXUS"], generatedAt: date(2025, 4))
        XCTAssertTrue(report.contains("| 持仓成本 |"))
        XCTAssertTrue(report.contains("| 浮动盈亏 |"))
        XCTAssertTrue(report.contains("剩余持仓成本"))
    }
}
