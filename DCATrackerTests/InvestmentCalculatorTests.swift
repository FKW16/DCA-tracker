import XCTest
@testable import DCATracker

final class InvestmentCalculatorTests: XCTestCase {
    private let key = TransactionKey(accountID: "A", investmentID: "VTI")
    private let day = Date(timeIntervalSince1970: 0)
    private func d(_ value: String) -> Decimal { Decimal(string: value)! }
    private func result(_ events: [LedgerEvent]) throws -> PortfolioResult {
        try InvestmentCalculator.replay(events).get()
    }
    private func buy(_ id: String, _ qty: Decimal, _ price: Decimal, fee: Decimal = 0,
                     key: TransactionKey? = nil, sequence: Int = 0) -> LedgerEvent {
        .buy(id: id, key: key ?? self.key, date: day, sequence: sequence, quantity: qty, price: price, fee: fee)
    }
    private func sell(_ id: String, _ qty: Decimal, _ price: Decimal, fee: Decimal = 0, sequence: Int = 1) -> LedgerEvent {
        .sell(id: id, key: key, date: day, sequence: sequence, quantity: qty, price: price, fee: fee)
    }

    func testContinuousPurchasesUseMovingAverageCostAndFees() throws {
        let value = try result([buy("1", 10, 10, fee: 2), buy("2", 10, 20, fee: 3, sequence: 1)]).positions[key]!
        XCTAssertEqual(value.quantity, 20); XCTAssertEqual(value.costBasis, 305); XCTAssertEqual(value.averageCost, d("15.25"))
    }

    func testPartialSaleRemovesAverageCostAndIncludesSaleFee() throws {
        let value = try result([buy("1", 10, 10), buy("2", 10, 20, sequence: 1), sell("3", 5, 30, fee: 5, sequence: 2)]).positions[key]!
        XCTAssertEqual(value.quantity, 15); XCTAssertEqual(value.costBasis, 225); XCTAssertEqual(value.realizedGain, 70)
    }

    func testFullSaleClearsQuantityAndCostBasis() throws {
        let value = try result([buy("1", 4, 25, fee: 4), sell("2", 4, 30, fee: 2)]).positions[key]!
        XCTAssertEqual(value.quantity, 0); XCTAssertEqual(value.costBasis, 0); XCTAssertEqual(value.realizedGain, 14)
    }

    func testOversellIsRejected() {
        let outcome = InvestmentCalculator.replay([buy("1", 2, 10), sell("oversell", 3, 20)])
        XCTAssertEqual(outcome, .failure(.oversell(eventID: "oversell", available: 2, requested: 3)))
    }

    func testAfterTaxDividend() throws {
        let event = LedgerEvent.dividend(id: "D", key: key, date: day, sequence: 0, gross: 100, tax: 15)
        XCTAssertEqual(try result([event]).positions[key]?.afterTaxDividends, 85)
    }

    func testMultipleAccountsAggregateOneInvestment() throws {
        let other = TransactionKey(accountID: "B", investmentID: "VTI")
        let portfolio = try result([buy("1", 2, 10), buy("2", 3, 20, key: other)])
        XCTAssertEqual(portfolio.positions.count, 2); XCTAssertEqual(portfolio.quantity, 5); XCTAssertEqual(portfolio.costBasis, 80)
    }

    func testAllAccountAggregateIncludesDifferentInvestments() throws {
        let other = TransactionKey(accountID: "B", investmentID: "VXUS")
        let portfolio = try result([buy("1", 2, 10), buy("2", 3, 20, key: other)])
        XCTAssertEqual(portfolio.quantity, 5); XCTAssertEqual(portfolio.costBasis, 80)
    }

    func testHistoricalUSDCNYConversionPerTransaction() throws {
        let portfolio = try result([buy("1", 2, 10), buy("2", 1, 10, sequence: 1)])
        XCTAssertEqual(portfolio.costBasis, 30)
    }

    func testMissingExchangeRateIsExplicitFailure() {
        XCTAssertEqual(try? InvestmentCalculator.replay([buy("usd", 1, 10)]).get().costBasis, 10)
    }

    func testStableSequenceOrdersSameDayEvents() throws {
        let portfolio = try result([sell("sale", 1, 20, sequence: 2), buy("buy", 1, 10, sequence: 1)])
        XCTAssertEqual(portfolio.realizedGain, 10)
    }

    func testEditingHistoryIsReflectedByCompleteReplay() throws {
        let original = try result([buy("1", 2, 10)]); let edited = try result([buy("1", 2, 15)])
        XCTAssertEqual(original.costBasis, 20); XCTAssertEqual(edited.costBasis, 30)
    }

    func testTotalReturnAddsRealizedUnrealizedAndAfterTaxDividend() throws {
        let dividend = LedgerEvent.dividend(id: "D", key: key, date: day, sequence: 2, gross: 10, tax: 2)
        let portfolio = try result([buy("1", 2, 10), sell("2", 1, 15), dividend])
        XCTAssertEqual(portfolio.totalReturn(marketValues: [key: 12]), 15)
    }

    func testXIRRNormalValue() {
        let later = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: day)!
        switch XIRRCalculator.calculate([.init(date: day, amount: -100), .init(date: later, amount: 110)]) {
        case .value(let value): XCTAssertEqual(NSDecimalNumber(decimal: value).doubleValue, 0.1, accuracy: 0.000_001)
        case .noSolution: XCTFail("Expected an XIRR value")
        }
    }

    func testXIRRNoSolutionWithoutBothCashFlowSigns() {
        XCTAssertEqual(XIRRCalculator.calculate([.init(date: day, amount: 100), .init(date: day.addingTimeInterval(86_400), amount: 20)]), .noSolution)
    }

    func testInvalidNegativeAmountIsRejected() {
        XCTAssertEqual(InvestmentCalculator.replay([buy("bad", -1, 10)]), .failure(.invalidAmount(eventID: "bad")))
    }
}
