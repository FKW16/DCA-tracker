import XCTest
import SwiftData
@testable import DCATracker

final class StrategyEngineTests: XCTestCase {
    func testPlanningWorkflowConfirmationUsesDCAResultAndCachedPrice() throws {
        let schema = Schema([BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self, TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)); let context = ModelContext(container)
        let account = BrokerageAccount(name: "A"), investment = Investment(symbol: "VTI", name: "VTI"); investment.latestPrice = 10
        let portfolio = InvestmentPortfolio(name: "P"); let asset = PortfolioAsset(investment: investment, targetWeight: 1, portfolio: portfolio)
        let plan = InvestmentPlan(name: "DCA", strategy: .dca, budget: .fixed, periodAmount: 999, totalBudget: 100, totalPeriods: 2, portfolio: portfolio)
        portfolio.assets = [asset]; portfolio.plans = [plan]
        context.insert(account); context.insert(investment); context.insert(portfolio); context.insert(asset); context.insert(plan)
        let suggestion = try StrategyEngine.suggest(PlanningWorkflow.input(plan: plan, portfolio: portfolio, purchases: [], sales: [])).get()
        XCTAssertEqual(suggestion.periodBudget, 50); XCTAssertEqual(suggestion.assets[0].priceSource, .cache)
        let created = PlanningWorkflow.confirm(suggestion, plan: plan, portfolio: portfolio, account: account, context: context)
        XCTAssertEqual(created.count, 1); XCTAssertEqual(created[0].quantity, 5); XCTAssertEqual(created[0].price, 10); XCTAssertEqual(plan.executions.first?.suggestedAmount, 50)
    }
    private func asset(_ id: String = "VTI", weight: Decimal = 1, quantity: Decimal = 0,
                       live: Decimal? = 10, cache: Decimal? = nil, manual: Decimal? = nil) -> AssetPlanInput {
        .init(id: id, weight: weight, currentQuantity: quantity, livePrice: live, cachedPrice: cache, manualPrice: manual)
    }
    private func input(strategy: StrategyKind = .dca, budget: BudgetKind = .unlimited, period: Int = 1,
                       amount: Decimal = 100, total: Decimal? = nil, periods: Int? = nil, spent: Decimal = 0,
                       initial: Decimal = 0, increment: Decimal = 100, assets: [AssetPlanInput]? = nil) -> StrategyPlanInput {
        .init(strategy: strategy, budget: budget, periodIndex: period, periodAmount: amount, totalBudget: total,
              totalPeriods: periods, spentAmount: spent, initialTargetValue: initial, targetIncrement: increment,
              assets: assets ?? [asset()])
    }
    private func value(_ input: StrategyPlanInput) throws -> StrategySuggestion { try StrategyEngine.suggest(input).get() }

    func testDCAUnlimitedUsesPeriodAmount() throws { XCTAssertEqual(try value(input()).periodBudget, 100) }
    func testDCAFixedDividesTotalBudget() throws { XCTAssertEqual(try value(input(budget: .fixed, total: 1000, periods: 4)).periodBudget, 250) }
    func testDCAFixedLastPeriodAbsorbsDecimalRemainder() throws {
        XCTAssertEqual(try value(input(budget: .fixed, period: 3, total: 100, periods: 3, spent: Decimal(string: "66.666666666666666666666666666666666666")!)).periodBudget,
                       Decimal(string: "33.333333333333333333333333333333333334")!)
    }
    func testFixedBudgetNeverExceedsRemaining() throws { XCTAssertEqual(try value(input(budget: .fixed, total: 100, periods: 4, spent: 90)).periodBudget, 10) }
    func testFixedBudgetExhaustionIsExplicit() { XCTAssertEqual(StrategyEngine.suggest(input(budget: .fixed, total: 100, periods: 4, spent: 100)), .failure(.budgetExhausted)) }
    func testInvalidWeightsRejected() { XCTAssertEqual(StrategyEngine.suggest(input(assets: [asset(weight: Decimal(string: "0.8")!)])), .failure(.invalidWeights(total: Decimal(string: "0.8")!))) }
    func testMultiAssetAllocationUsesWeights() throws {
        let result = try value(input(assets: [asset("VTI", weight: Decimal(string: "0.6")!), asset("VXUS", weight: Decimal(string: "0.4")!, live: 20)]))
        XCTAssertEqual(result.assets.map(\.amount), [60, 40])
    }
    func testMissingPriceIsExplicit() { XCTAssertEqual(StrategyEngine.suggest(input(assets: [asset(live: nil)])), .failure(.missingPrice(assetID: "VTI"))) }
    func testCachedPriceFallback() throws { XCTAssertEqual(try value(input(assets: [asset(live: nil, cache: 8)])).assets[0].priceSource, .cache) }
    func testManualPriceFallback() throws { XCTAssertEqual(try value(input(assets: [asset(live: nil, manual: 8)])).assets[0].priceSource, .manual) }
    func testSharesRoundedToSixPlaces() { XCTAssertEqual(StrategyEngine.suggest(input(amount: 1, assets: [asset(live: 3)])), .failure(.insufficientBudget)) }
    func testIntegerSharesNeverExceedBudget() throws { let value = try value(input(amount: 100, assets: [asset("A", weight: 0.5, live: 30), asset("B", weight: 0.5, live: 40)])); XCTAssertTrue(value.assets.allSatisfy { NSDecimalNumber(decimal: $0.shares).doubleValue.rounded(.down) == NSDecimalNumber(decimal: $0.shares).doubleValue }); XCTAssertLessThanOrEqual(value.estimatedSpend, 100); XCTAssertEqual(value.estimatedSpend + value.remainingCash, 100) }
    func testIntegerOptimizerIsDeterministic() throws { let plan = input(amount: 100, assets: [asset("B", weight: 0.5, live: 30), asset("A", weight: 0.5, live: 30)]); XCTAssertEqual(try value(plan), try value(plan)) }
    func testInsufficientBudgetIsExplicit() { XCTAssertEqual(StrategyEngine.suggest(input(amount: 5, assets: [asset(live: 10)])), .failure(.insufficientBudget)) }
    func testTinyWeightInputErrorIsNormalized() throws { let almost = Decimal(string: "0.9999999")!; XCTAssertEqual(try value(input(assets: [asset(weight: almost)])).assets.count, 1) }
    func testIntegerOptimizerChoosesGlobalMinimumDeviationNotGreedySpend() throws {
        let result = try value(input(amount: 70, assets: [asset("A", weight: 0.5, live: 40), asset("B", weight: 0.5, live: 30)]))
        XCTAssertEqual(result.assets.map(\.shares), [1, 1]); XCTAssertEqual(result.estimatedSpend, 70)
    }
    func testIntegerOptimizerPrioritizesUsingBudgetThenChoosesClosestWeights() throws {
        let result = try value(input(amount: 100, assets: [asset("A", weight: 0.8, live: 60), asset("B", weight: 0.2, live: 20)]))
        XCTAssertEqual(result.estimatedSpend, 100); XCTAssertEqual(result.assets.map(\.shares), [1, 2])
    }
    func testIntegerOptimizerDoesNotLeaveLargeCashBalanceForPerfectRatio() throws {
        let result = try value(input(amount: 11_000, assets: [asset("A", weight: 0.6, live: Decimal(string: "317.31")!), asset("B", weight: 0.4, live: Decimal(string: "113.27")!)]))
        XCTAssertLessThan(result.remainingCash, Decimal(string: "113.27")!); XCTAssertEqual(result.estimatedSpend + result.remainingCash, 11_000)
    }
    func testExactSpendingCheapAssetDoesNotCrowdOutQQQM() throws {
        let result = try value(input(amount: 2_000, assets: [asset("QQQM", weight: 0.5, live: 210), asset("OTHER", weight: 0.5, live: 100)]))
        XCTAssertGreaterThan(result.assets[0].shares, 0)
        XCTAssertLessThan(result.remainingCash, 100)
        XCTAssertLessThan(result.assets.reduce(0) { $0 + $1.weightDeviation }, Decimal(string: "0.1")!)
    }
    func testRepeatedContributionsKeepBuyingHigherPricedTargetAsset() throws {
        var qqqmQuantity: Decimal = 0, otherQuantity: Decimal = 0
        for _ in 0..<8 {
            let result = try value(input(amount: 2_000, assets: [
                asset("QQQM", weight: 0.5, quantity: qqqmQuantity, live: 210),
                asset("OTHER", weight: 0.5, quantity: otherQuantity, live: 100)
            ]))
            let qqqmPurchase = result.assets[0].shares
            XCTAssertGreaterThan(qqqmPurchase, 0)
            qqqmQuantity += qqqmPurchase; otherQuantity += result.assets[1].shares
        }
        let qqqmValue = qqqmQuantity * 210, otherValue = otherQuantity * 100
        XCTAssertLessThan(abs(qqqmValue / (qqqmValue + otherValue) - 0.5), Decimal(string: "0.03")!)
    }
    func testSinglePlanMigrationCreatesBackupAndIsIdempotent() throws {
        let schema = Schema([BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self, TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)), context = ModelContext(container)
        let investment = Investment(symbol: "VTI", name: "VTI"), first = InvestmentPortfolio(name: "old1"), second = InvestmentPortfolio(name: "old2")
        let firstPlan = InvestmentPlan(name: "p1", strategy: .dca, budget: .unlimited, periodAmount: 10, portfolio: first)
        let secondPlan = InvestmentPlan(name: "p2", strategy: .dca, budget: .unlimited, periodAmount: 20, portfolio: second)
        context.insert(investment); context.insert(first); context.insert(second); context.insert(firstPlan); context.insert(secondPlan); try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try SinglePlanCoordinator.save(monthlyAmount: 100, investments: [investment], enabledIDs: [investment.id], weights: [investment.id: 1], portfolios: [first, second], context: context, backupDirectory: directory)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InvestmentPortfolio>()), 1); XCTAssertEqual(try context.fetchCount(FetchDescriptor<InvestmentPlan>()), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
        let remaining = try context.fetch(FetchDescriptor<InvestmentPortfolio>())
        _ = try SinglePlanCoordinator.save(monthlyAmount: 100, investments: [investment], enabledIDs: [investment.id], weights: [investment.id: 1], portfolios: remaining, context: context, backupDirectory: directory)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InvestmentPortfolio>()), 1); XCTAssertEqual(try context.fetchCount(FetchDescriptor<InvestmentPlan>()), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }
    func testSinglePlanMigrationMergesAssetsFromSecondaryPortfolio() throws {
        let schema = Schema([BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self, TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)), context = ModelContext(container)
        let firstInvestment = Investment(symbol: "VTI", name: "VTI"), secondInvestment = Investment(symbol: "VXUS", name: "VXUS")
        let first = InvestmentPortfolio(name: "old1"), second = InvestmentPortfolio(name: "old2")
        let firstAsset = PortfolioAsset(investment: firstInvestment, targetWeight: 1, portfolio: first)
        let secondAsset = PortfolioAsset(investment: secondInvestment, targetWeight: 1, portfolio: second)
        first.assets = [firstAsset]; second.assets = [secondAsset]
        let firstPlan = InvestmentPlan(name: "p1", strategy: .dca, budget: .unlimited, periodAmount: 10, portfolio: first)
        let secondPlan = InvestmentPlan(name: "p2", strategy: .dca, budget: .unlimited, periodAmount: 20, portfolio: second)
        context.insert(firstInvestment); context.insert(secondInvestment); context.insert(first); context.insert(second)
        context.insert(firstAsset); context.insert(secondAsset); context.insert(firstPlan); context.insert(secondPlan)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try SinglePlanCoordinator.save(monthlyAmount: 100, investments: [firstInvestment, secondInvestment], enabledIDs: [firstInvestment.id], weights: [firstInvestment.id: 1], portfolios: [first, second], context: context, backupDirectory: directory)
        let remaining = try XCTUnwrap(context.fetch(FetchDescriptor<InvestmentPortfolio>()).first)
        XCTAssertEqual(Set(remaining.assets.compactMap { $0.investment?.symbol }), Set(["VTI", "VXUS"]))
        XCTAssertEqual(remaining.assets.reduce(0) { $0 + $1.targetWeight }, 1)
    }
}
