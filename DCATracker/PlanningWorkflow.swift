import Foundation
import SwiftData

enum PlanningWorkflow {
    static func input(plan: InvestmentPlan, portfolio: InvestmentPortfolio,
                      purchases: [Purchase], sales: [Sale]) -> StrategyPlanInput {
        let assets = portfolio.assets.compactMap { asset -> AssetPlanInput? in
            guard let investment = asset.investment else { return nil }
            let bought = purchases.filter { $0.investment?.id == investment.id }.reduce(0) { $0 + $1.quantity }
            let sold = sales.filter { $0.investment?.id == investment.id }.reduce(0) { $0 + $1.quantity }
            return .init(id: investment.id.uuidString, weight: asset.targetWeight, currentQuantity: bought - sold,
                         livePrice: nil, cachedPrice: investment.latestPrice, manualPrice: investment.manualPrice)
        }
        let spent = plan.executions.compactMap { $0.confirmedAt == nil ? nil : $0.suggestedAmount }.reduce(0, +)
        return .init(strategy: StrategyKind(rawValue: plan.strategyRaw) ?? .dca,
                     budget: BudgetKind(rawValue: plan.budgetRaw) ?? .unlimited,
                     periodIndex: plan.completedPeriods + 1, periodAmount: plan.periodAmount,
                     totalBudget: plan.totalBudget, totalPeriods: plan.totalPeriods, spentAmount: spent,
                     initialTargetValue: plan.initialTargetValue, targetIncrement: plan.targetIncrement, assets: assets)
    }

    @discardableResult
    static func confirm(_ suggestion: StrategySuggestion, plan: InvestmentPlan, portfolio: InvestmentPortfolio,
                        account: BrokerageAccount, context: ModelContext, date: Date = Date()) -> [Purchase] {
        let investments = Dictionary(uniqueKeysWithValues: portfolio.assets.compactMap { asset in asset.investment.map { ($0.id.uuidString, $0) } })
        let purchases = suggestion.assets.compactMap { item -> Purchase? in
            guard item.shares > 0, item.shares == item.shares.rounded(.down), let investment = investments[item.assetID] else { return nil }
            let purchase = Purchase(date: date, sequence: plan.completedPeriods, quantity: item.shares, price: item.price,
                                    note: "计划建议确认（\(item.priceSource.rawValue)）", account: account, investment: investment)
            context.insert(purchase); return purchase
        }
        let execution = PlanExecution(periodIndex: plan.completedPeriods + 1, suggestedAmount: suggestion.periodBudget, plan: plan)
        execution.confirmedAt = date; context.insert(execution); plan.completedPeriods += 1
        return purchases
    }
}

enum SinglePlanCoordinator {
    static let canonicalPortfolioName = "全局 DCA 组合"
    static let canonicalPlanName = "每月 DCA 计划"

    static func validateWeights(_ values: [UUID: Decimal], enabledIDs: Set<UUID>) -> Result<[UUID: Decimal], StrategyError> {
        let enabled = values.filter { enabledIDs.contains($0.key) }
        guard !enabled.isEmpty, enabled.values.allSatisfy({ $0 > 0 }) else { return .failure(.invalidPositiveValue) }
        let total = enabled.values.reduce(0, +), tolerance = Decimal(string: "0.000001")!
        guard abs(total - 1) <= tolerance else { return .failure(.invalidWeights(total: total)) }
        return .success(enabled.mapValues { $0 / total })
    }

    @discardableResult
    static func save(monthlyAmount: Decimal, investments: [Investment], enabledIDs: Set<UUID>, weights: [UUID: Decimal],
                     portfolios: [InvestmentPortfolio], context: ModelContext, backupDirectory: URL? = nil) throws -> InvestmentPlan {
        guard monthlyAmount > 0 else { throw StrategyError.invalidPositiveValue }
        let ordered = portfolios.sorted { $0.createdAt < $1.createdAt }
        let allPlans = ordered.flatMap(\.plans).sorted { $0.startDate < $1.startDate }
        let isLegacyMigration = ordered.count > 1 || allPlans.count > 1
        if isLegacyMigration {
            try writeMigrationBackup(portfolios: ordered, plans: allPlans, directory: backupDirectory)
        }
        var effectiveIDs = enabledIDs
        var effectiveWeights = weights
        if isLegacyMigration {
            for asset in ordered.flatMap(\.assets) {
                guard let investment = asset.investment, asset.targetWeight > 0 else { continue }
                effectiveIDs.insert(investment.id)
                if effectiveWeights[investment.id] == nil { effectiveWeights[investment.id] = asset.targetWeight }
            }
            let total = effectiveIDs.compactMap { effectiveWeights[$0] }.reduce(0, +)
            guard total > 0 else { throw StrategyError.invalidPositiveValue }
            for id in effectiveIDs { effectiveWeights[id] = (effectiveWeights[id] ?? 0) / total }
        }
        let normalized = try validateWeights(effectiveWeights, enabledIDs: effectiveIDs).get()
        let portfolio = ordered.first ?? InvestmentPortfolio(name: canonicalPortfolioName)
        if ordered.isEmpty { context.insert(portfolio) }
        portfolio.name = canonicalPortfolioName
        let plans = allPlans
        let plan = plans.first ?? InvestmentPlan(name: canonicalPlanName, strategy: .dca, budget: .unlimited, periodAmount: monthlyAmount, portfolio: portfolio)
        if plans.isEmpty { context.insert(plan) }
        plan.name = canonicalPlanName; plan.strategyRaw = StrategyKind.dca.rawValue; plan.budgetRaw = BudgetKind.unlimited.rawValue
        plan.periodAmount = monthlyAmount; plan.targetIncrement = monthlyAmount; plan.portfolio = portfolio
        let desired = Dictionary(uniqueKeysWithValues: investments.filter { effectiveIDs.contains($0.id) }.map { ($0.id, $0) })
        for asset in portfolio.assets where desired[asset.investment?.id ?? UUID()] == nil { context.delete(asset) }
        for (id, investment) in desired {
            if let existing = portfolio.assets.first(where: { $0.investment?.id == id }) { existing.targetWeight = normalized[id]! }
            else { context.insert(PortfolioAsset(investment: investment, targetWeight: normalized[id]!, portfolio: portfolio)) }
        }
        for extra in ordered.dropFirst() { context.delete(extra) }
        for extra in plans.dropFirst() { context.delete(extra) }
        try context.save(); return plan
    }

    private struct LegacyPlanSnapshot: Codable {
        struct Portfolio: Codable { let id: UUID; let name: String; let createdAt: Date; let assets: [Asset] }
        struct Asset: Codable { let investmentID: UUID?; let weight: Decimal }
        struct Plan: Codable { let id: UUID; let portfolioID: UUID?; let name: String; let startDate: Date; let amount: Decimal }
        let createdAt: Date; let portfolios: [Portfolio]; let plans: [Plan]
    }

    private static func writeMigrationBackup(portfolios: [InvestmentPortfolio], plans: [InvestmentPlan], directory: URL?) throws {
        let target: URL
        if let directory { target = directory } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            target = support.appendingPathComponent("DCA Tracker/MigrationBackups", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let snapshot = LegacyPlanSnapshot(createdAt: Date(), portfolios: portfolios.map { portfolio in
            .init(id: portfolio.id, name: portfolio.name, createdAt: portfolio.createdAt, assets: portfolio.assets.map { .init(investmentID: $0.investment?.id, weight: $0.targetWeight) })
        }, plans: plans.map { .init(id: $0.id, portfolioID: $0.portfolio?.id, name: $0.name, startDate: $0.startDate, amount: $0.periodAmount) })
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: target.appendingPathComponent("plans-before-single-plan-\(UUID().uuidString).json"), options: .atomic)
    }
}

private extension Decimal { func rounded(_ mode: Decimal.RoundingMode) -> Decimal { var source = self, result = Decimal(); NSDecimalRound(&result, &source, 0, mode); return result } }
