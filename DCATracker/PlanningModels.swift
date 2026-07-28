import Foundation
import SwiftData

enum StrategyKind: String, Codable, CaseIterable { case dca }
enum BudgetKind: String, Codable, CaseIterable { case fixed, unlimited }
enum PlanStatus: String, Codable, CaseIterable { case active, paused, completed }
enum PlanFrequency: String, Codable, CaseIterable { case weekly, monthly, quarterly }

@Model final class InvestmentPortfolio {
    @Attribute(.unique) var id: UUID
    var name: String
    var currencyCode: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \PortfolioAsset.portfolio) var assets: [PortfolioAsset]
    @Relationship(deleteRule: .cascade, inverse: \InvestmentPlan.portfolio) var plans: [InvestmentPlan]
    init(name: String, currency: CurrencyCode = .usd) {
        id = UUID(); self.name = name; currencyCode = currency.rawValue; createdAt = Date(); assets = []; plans = []
    }
}

@Model final class PortfolioAsset {
    @Attribute(.unique) var id: UUID
    var targetWeight: Decimal
    var portfolio: InvestmentPortfolio?
    var investment: Investment?
    init(investment: Investment, targetWeight: Decimal, portfolio: InvestmentPortfolio) {
        id = UUID(); self.investment = investment; self.targetWeight = targetWeight; self.portfolio = portfolio
    }
}

@Model final class InvestmentPlan {
    @Attribute(.unique) var id: UUID
    var name: String
    var strategyRaw: String
    var budgetRaw: String
    var statusRaw: String
    var frequencyRaw: String
    var startDate: Date
    var periodAmount: Decimal
    var totalBudget: Decimal?
    var totalPeriods: Int?
    var initialTargetValue: Decimal
    var targetIncrement: Decimal
    var completedPeriods: Int
    var portfolio: InvestmentPortfolio?
    @Relationship(deleteRule: .cascade, inverse: \PlanExecution.plan) var executions: [PlanExecution]
    init(name: String, strategy: StrategyKind, budget: BudgetKind, periodAmount: Decimal,
         totalBudget: Decimal? = nil, totalPeriods: Int? = nil, portfolio: InvestmentPortfolio) {
        id = UUID(); self.name = name; strategyRaw = strategy.rawValue; budgetRaw = budget.rawValue
        statusRaw = PlanStatus.active.rawValue; frequencyRaw = PlanFrequency.monthly.rawValue; startDate = Date()
        self.periodAmount = periodAmount; self.totalBudget = totalBudget; self.totalPeriods = totalPeriods
        initialTargetValue = 0; targetIncrement = periodAmount; completedPeriods = 0; self.portfolio = portfolio; executions = []
    }
}

@Model final class PlanExecution {
    @Attribute(.unique) var id: UUID
    var periodIndex: Int
    var suggestedAmount: Decimal
    var confirmedAt: Date?
    var plan: InvestmentPlan?
    init(periodIndex: Int, suggestedAmount: Decimal, plan: InvestmentPlan) {
        id = UUID(); self.periodIndex = periodIndex; self.suggestedAmount = suggestedAmount; self.plan = plan
    }
}
