import XCTest
import SwiftData
@testable import DCATracker

final class ModelTests: XCTestCase {
    func testNewFieldsPersistInSwiftData() throws {
        let schema = Schema([BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self, TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)); let context = ModelContext(container)
        let account = BrokerageAccount(name: "A", note: "长期"); let investment = Investment(symbol: "vti", name: "VTI", exchange: "NASDAQ"); investment.latestPrice = 250
        context.insert(account); context.insert(investment); try context.save(); context.rollback()
        XCTAssertEqual(try context.fetch(FetchDescriptor<BrokerageAccount>()).first?.note, "长期")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Investment>()).first?.exchange, "NASDAQ"); XCTAssertEqual(try context.fetch(FetchDescriptor<Investment>()).first?.latestPrice, 250)
    }
    func testNewModelDefaultsAreMigrationSafe() {
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "vti", name: "VTI")
        XCTAssertEqual(account.note, ""); XCTAssertEqual(investment.exchange, ""); XCTAssertNil(investment.latestPrice)
        XCTAssertNil(investment.previousClose); XCTAssertNil(investment.quoteUpdatedAt); XCTAssertTrue(investment.isWatched)
    }

    func testEditableActualDividendOverridesDefaultNetAmount() {
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI")
        let dividend = Dividend(date: Date(), grossAmount: 100, withholdingTax: 15, account: account, investment: investment)
        XCTAssertEqual(dividend.receivedAmount, 85); dividend.actualReceivedAmount = 82; XCTAssertEqual(dividend.receivedAmount, 82)
        let event = InvestmentCalculator.dividendEvent(from: dividend, key: .init(accountID: "A", investmentID: "VTI"))
        XCTAssertEqual(try? InvestmentCalculator.replay([event]).get().afterTaxDividends, 82)
    }

    func testTransactionTagFilterCoversAllTransactionTypes() {
        let tag = TransactionTag(name: "定投"), ids = Set([tag.id])
        XCTAssertTrue(TransactionFilter.matches(tags: [tag], selectedTagIDs: ids)); XCTAssertFalse(TransactionFilter.matches(tags: [], selectedTagIDs: ids))
        XCTAssertTrue(TransactionFilter.matches(tags: [], selectedTagIDs: []))
    }
    func testInvestmentSymbolIsUppercasedOnCreateAndEdit() {
        let investment = Investment(symbol: " vti ", name: "Vanguard Total Stock Market")
        XCTAssertEqual(investment.symbol, "VTI")
        investment.symbol = "vxus"
        XCTAssertEqual(investment.symbol, "VXUS")
    }

    func testArchivedAccountRetainsIdentityAndHistoryFlag() {
        let account = BrokerageAccount(name: "Historical", isArchived: true)
        XCTAssertTrue(account.isArchived)
        XCTAssertEqual(account.name, "Historical")
    }

    func testDeletingInvestmentRemovesTransactionsAndPortfolioAsset() throws {
        let schema = Schema([BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self, TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI"), portfolio = InvestmentPortfolio(name: "P")
        let asset = PortfolioAsset(investment: investment, targetWeight: 1, portfolio: portfolio)
        context.insert(account); context.insert(investment); context.insert(portfolio); context.insert(asset)
        context.insert(Purchase(date: Date(), quantity: 1, price: 100, account: account, investment: investment))
        context.insert(Sale(date: Date(), quantity: 1, price: 110, account: account, investment: investment))
        context.insert(Dividend(date: Date(), grossAmount: 2, account: account, investment: investment))
        try context.save()

        try InvestmentDeletionService.delete(investment, portfolioAssets: [asset], context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Investment>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PortfolioAsset>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Purchase>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Sale>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Dividend>()).isEmpty)
    }
}
