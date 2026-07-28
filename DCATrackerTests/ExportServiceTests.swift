import XCTest
import SwiftData
@testable import DCATracker

final class ExportServiceTests: XCTestCase {
    private func container() throws -> ModelContainer { try ModelContainer(for: Schema([BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self, TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true)) }
    func testFullBackupContainsSettingsModelsTagsQuoteCacheAndTransactionsButNoAPIKey() throws {
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI"); investment.latestPrice = 12; investment.previousClose = 11; investment.quoteUpdatedAt = Date(timeIntervalSince1970: 2)
        let tag = TransactionTag(name: "定投"), purchase = Purchase(date: Date(), quantity: 1, price: 10, account: account, investment: investment); purchase.tags = [tag]
        let portfolio = InvestmentPortfolio(name: "P"), asset = PortfolioAsset(investment: investment, targetWeight: 1, portfolio: portfolio), plan = InvestmentPlan(name: "Plan", strategy: .dca, budget: .unlimited, periodAmount: 100, portfolio: portfolio)
        let execution = PlanExecution(periodIndex: 1, suggestedAmount: 100, plan: plan)
        let graph = BackupGraph(accounts: [account], investments: [investment], tags: [tag], purchases: [purchase], sales: [], dividends: [], portfolios: [portfolio], assets: [asset], plans: [plan], executions: [execution])
        let data = try FullBackupService.encode(FullBackupService.capture(graph)); let decoded = try FullBackupService.decode(data)
        XCTAssertEqual(decoded.preferences.quoteProvider, "Twelve Data"); XCTAssertEqual(decoded.investments[0].latestPrice, 12); XCTAssertEqual(decoded.tags.count, 1); XCTAssertEqual(decoded.portfolios.count, 1); XCTAssertEqual(decoded.plans.count, 1); XCTAssertEqual(decoded.transactions.count, 1)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.lowercased().contains("apikey"))
    }
    func testFullRestoreDeduplicatesAccountsInvestmentsAndTransactionsByID() throws {
        let source = try container(), sourceContext = ModelContext(source); let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI"), purchase = Purchase(date: Date(), quantity: 1, price: 10, account: account, investment: investment)
        let backup = FullBackupService.capture(.init(accounts: [account], investments: [investment], tags: [], purchases: [purchase], sales: [], dividends: [], portfolios: [], assets: [], plans: [], executions: []))
        let target = try container(), context = ModelContext(target); try FullBackupService.restore(backup, into: context); try FullBackupService.restore(backup, into: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BrokerageAccount>()), 1); XCTAssertEqual(try context.fetchCount(FetchDescriptor<Investment>()), 1); XCTAssertEqual(try context.fetchCount(FetchDescriptor<Purchase>()), 1)
        _ = sourceContext
    }
    private let record = LedgerRecord(id: UUID(), type: "buy", date: Date(timeIntervalSince1970: 0), symbol: "VTI", account: "Broker", quantity: 1, price: 10, amount: 10, tags: ["定投"], note: "a,b")
    func testCSVIncludesReadableLedgerAndEscapesComma() {
        let text = String(data: ExportService.csv([record]), encoding: .utf8)!
        XCTAssertTrue(text.contains("type,date,symbol")); XCTAssertTrue(text.contains("\"a,b\"")); XCTAssertTrue(text.contains("VTI"))
    }
    func testJSONBackupRoundTripsVersionedEnvelope() throws {
        let data = try ExportService.backup([record], date: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(try ExportService.validateAndDecode(data).records, [record])
    }
    func testJSONBackupRejectsUnknownVersion() throws {
        let data = Data(#"{"version":99,"createdAt":"1970-01-01T00:00:00Z","records":[]}"#.utf8)
        XCTAssertThrowsError(try ExportService.validateAndDecode(data)) { XCTAssertEqual($0 as? BackupError, .unsupportedVersion(99)) }
    }
    func testSafetyCopyIsCreatedInChosenDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ExportService.safetyCopy(of: Data("safe".utf8), in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); XCTAssertEqual(try Data(contentsOf: url), Data("safe".utf8))
    }
}
