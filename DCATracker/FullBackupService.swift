import Foundation
import SwiftData

struct BackupAccount: Codable, Equatable { let id: UUID; let name, broker, note, currencyCode: String; let isArchived: Bool; let createdAt: Date }
struct BackupInvestment: Codable, Equatable { let id: UUID; let symbol, name, currencyCode, exchange: String; let latestPrice, previousClose, manualPrice: Decimal?; let quoteUpdatedAt: Date?; let isWatched: Bool; let createdAt: Date }
struct BackupTag: Codable, Equatable { let id: UUID; let name, colorHex: String }
struct BackupTransaction: Codable, Equatable {
    let id: UUID; let kind: String; let date: Date; let sequence: Int; let quantity, price, fee, grossAmount, withholdingTax, actualReceivedAmount: Decimal?
    let note: String; let accountID, investmentID: UUID; let tagIDs: [UUID]
}
struct BackupPortfolio: Codable, Equatable { let id: UUID; let name, currencyCode: String; let createdAt: Date }
struct BackupPortfolioAsset: Codable, Equatable { let id, portfolioID, investmentID: UUID; let targetWeight: Decimal }
struct BackupPlan: Codable, Equatable {
    let id, portfolioID: UUID; let name, strategyRaw, budgetRaw, statusRaw, frequencyRaw: String; let startDate: Date
    let periodAmount, totalBudget, initialTargetValue, targetIncrement: Decimal?; let totalPeriods: Int?; let completedPeriods: Int
}
struct BackupExecution: Codable, Equatable { let id, planID: UUID; let periodIndex: Int; let suggestedAmount: Decimal; let confirmedAt: Date? }
struct BackupPreferences: Codable, Equatable { let quoteProvider: String; let refreshOnLaunch: Bool }
struct FullBackupEnvelope: Codable, Equatable {
    static let currentVersion = 2
    let version: Int; let createdAt: Date; let preferences: BackupPreferences
    let accounts: [BackupAccount]; let investments: [BackupInvestment]; let tags: [BackupTag]; let transactions: [BackupTransaction]
    let portfolios: [BackupPortfolio]; let portfolioAssets: [BackupPortfolioAsset]; let plans: [BackupPlan]; let executions: [BackupExecution]
}
struct BackupGraph {
    let accounts: [BrokerageAccount]; let investments: [Investment]; let tags: [TransactionTag]
    let purchases: [Purchase]; let sales: [Sale]; let dividends: [Dividend]
    let portfolios: [InvestmentPortfolio]; let assets: [PortfolioAsset]; let plans: [InvestmentPlan]; let executions: [PlanExecution]
}

enum FullBackupService {
    static func capture(_ graph: BackupGraph, date: Date = Date()) -> FullBackupEnvelope {
        let transactions = graph.purchases.map { BackupTransaction(id: $0.id, kind: "buy", date: $0.date, sequence: $0.sequence, quantity: $0.quantity, price: $0.price, fee: $0.fee, grossAmount: nil, withholdingTax: nil, actualReceivedAmount: nil, note: $0.note, accountID: $0.account!.id, investmentID: $0.investment!.id, tagIDs: $0.tags.map(\.id)) } +
            graph.sales.map { BackupTransaction(id: $0.id, kind: "sell", date: $0.date, sequence: $0.sequence, quantity: $0.quantity, price: $0.price, fee: $0.fee, grossAmount: nil, withholdingTax: nil, actualReceivedAmount: nil, note: $0.note, accountID: $0.account!.id, investmentID: $0.investment!.id, tagIDs: $0.tags.map(\.id)) } +
            graph.dividends.map { BackupTransaction(id: $0.id, kind: "dividend", date: $0.date, sequence: $0.sequence, quantity: nil, price: nil, fee: nil, grossAmount: $0.grossAmount, withholdingTax: $0.withholdingTax, actualReceivedAmount: $0.actualReceivedAmount, note: $0.note, accountID: $0.account!.id, investmentID: $0.investment!.id, tagIDs: $0.tags.map(\.id)) }
        return .init(version: FullBackupEnvelope.currentVersion, createdAt: date, preferences: .init(quoteProvider: "Twelve Data", refreshOnLaunch: true),
            accounts: graph.accounts.map { .init(id: $0.id, name: $0.name, broker: $0.broker, note: $0.note, currencyCode: $0.currencyCode, isArchived: $0.isArchived, createdAt: $0.createdAt) },
            investments: graph.investments.map { .init(id: $0.id, symbol: $0.symbol, name: $0.name, currencyCode: $0.currencyCode, exchange: $0.exchange, latestPrice: $0.latestPrice, previousClose: $0.previousClose, manualPrice: $0.manualPrice, quoteUpdatedAt: $0.quoteUpdatedAt, isWatched: $0.isWatched, createdAt: $0.createdAt) },
            tags: graph.tags.map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex) }, transactions: transactions,
            portfolios: graph.portfolios.map { .init(id: $0.id, name: $0.name, currencyCode: $0.currencyCode, createdAt: $0.createdAt) },
            portfolioAssets: graph.assets.compactMap { guard let p = $0.portfolio, let i = $0.investment else { return nil }; return .init(id: $0.id, portfolioID: p.id, investmentID: i.id, targetWeight: $0.targetWeight) },
            plans: graph.plans.compactMap { guard let p = $0.portfolio else { return nil }; return .init(id: $0.id, portfolioID: p.id, name: $0.name, strategyRaw: $0.strategyRaw, budgetRaw: $0.budgetRaw, statusRaw: $0.statusRaw, frequencyRaw: $0.frequencyRaw, startDate: $0.startDate, periodAmount: $0.periodAmount, totalBudget: $0.totalBudget, initialTargetValue: $0.initialTargetValue, targetIncrement: $0.targetIncrement, totalPeriods: $0.totalPeriods, completedPeriods: $0.completedPeriods) },
            executions: graph.executions.compactMap { guard let p = $0.plan else { return nil }; return .init(id: $0.id, planID: p.id, periodIndex: $0.periodIndex, suggestedAmount: $0.suggestedAmount, confirmedAt: $0.confirmedAt) })
    }
    static func encode(_ value: FullBackupEnvelope) throws -> Data { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(value) }
    static func decode(_ data: Data) throws -> FullBackupEnvelope { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; guard let value = try? decoder.decode(FullBackupEnvelope.self, from: data) else { throw BackupError.invalidData }; guard value.version == FullBackupEnvelope.currentVersion else { throw BackupError.unsupportedVersion(value.version) }; return value }

    static func restore(_ backup: FullBackupEnvelope, into context: ModelContext) throws {
        var accounts = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BrokerageAccount>()).map { ($0.id, $0) })
        for value in backup.accounts { let item = accounts[value.id] ?? BrokerageAccount(name: value.name); item.id = value.id; item.name = value.name; item.broker = value.broker; item.note = value.note; item.currencyCode = value.currencyCode; item.isArchived = value.isArchived; item.createdAt = value.createdAt; if accounts[value.id] == nil { context.insert(item); accounts[value.id] = item } }
        var investments = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Investment>()).map { ($0.id, $0) })
        for value in backup.investments { let item = investments[value.id] ?? Investment(symbol: value.symbol, name: value.name); item.id = value.id; item.symbol = value.symbol; item.name = value.name; item.currencyCode = value.currencyCode; item.exchange = value.exchange; item.latestPrice = value.latestPrice; item.previousClose = value.previousClose; item.manualPrice = value.manualPrice; item.quoteUpdatedAt = value.quoteUpdatedAt; item.isWatched = value.isWatched; item.createdAt = value.createdAt; if investments[value.id] == nil { context.insert(item); investments[value.id] = item } }
        var tags = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransactionTag>()).map { ($0.id, $0) })
        for value in backup.tags { let item = tags[value.id] ?? TransactionTag(name: value.name); item.id = value.id; item.name = value.name; item.colorHex = value.colorHex; if tags[value.id] == nil { context.insert(item); tags[value.id] = item } }
        var portfolios = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InvestmentPortfolio>()).map { ($0.id, $0) })
        for value in backup.portfolios { let item = portfolios[value.id] ?? InvestmentPortfolio(name: value.name); item.id = value.id; item.name = value.name; item.currencyCode = value.currencyCode; item.createdAt = value.createdAt; if portfolios[value.id] == nil { context.insert(item); portfolios[value.id] = item } }
        var plans = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InvestmentPlan>()).map { ($0.id, $0) })
        for value in backup.plans { guard let portfolio = portfolios[value.portfolioID] else { continue }; let item = plans[value.id] ?? InvestmentPlan(name: value.name, strategy: StrategyKind(rawValue: value.strategyRaw) ?? .dca, budget: BudgetKind(rawValue: value.budgetRaw) ?? .unlimited, periodAmount: value.periodAmount ?? 0, portfolio: portfolio); item.id = value.id; item.name = value.name; item.strategyRaw = value.strategyRaw; item.budgetRaw = value.budgetRaw; item.statusRaw = value.statusRaw; item.frequencyRaw = value.frequencyRaw; item.startDate = value.startDate; item.periodAmount = value.periodAmount ?? 0; item.totalBudget = value.totalBudget; item.totalPeriods = value.totalPeriods; item.initialTargetValue = value.initialTargetValue ?? 0; item.targetIncrement = value.targetIncrement ?? 0; item.completedPeriods = value.completedPeriods; item.portfolio = portfolio; if plans[value.id] == nil { context.insert(item); plans[value.id] = item } }
        let assetIDs = Set(try context.fetch(FetchDescriptor<PortfolioAsset>()).map(\.id)); for value in backup.portfolioAssets where !assetIDs.contains(value.id) { if let investment = investments[value.investmentID], let portfolio = portfolios[value.portfolioID] { let item = PortfolioAsset(investment: investment, targetWeight: value.targetWeight, portfolio: portfolio); item.id = value.id; context.insert(item) } }
        let executionIDs = Set(try context.fetch(FetchDescriptor<PlanExecution>()).map(\.id)); for value in backup.executions where !executionIDs.contains(value.id) { if let plan = plans[value.planID] { let item = PlanExecution(periodIndex: value.periodIndex, suggestedAmount: value.suggestedAmount, plan: plan); item.id = value.id; item.confirmedAt = value.confirmedAt; context.insert(item) } }
        let existing = Set(try context.fetch(FetchDescriptor<Purchase>()).map(\.id) + context.fetch(FetchDescriptor<Sale>()).map(\.id) + context.fetch(FetchDescriptor<Dividend>()).map(\.id))
        for value in backup.transactions where !existing.contains(value.id) { guard let account = accounts[value.accountID], let investment = investments[value.investmentID] else { continue }; let assignedTags = value.tagIDs.compactMap { tags[$0] }; if value.kind == "buy" { let item = Purchase(date: value.date, sequence: value.sequence, quantity: value.quantity ?? 0, price: value.price ?? 0, fee: value.fee ?? 0, note: value.note, account: account, investment: investment); item.id = value.id; item.tags = assignedTags; context.insert(item) } else if value.kind == "sell" { let item = Sale(date: value.date, sequence: value.sequence, quantity: value.quantity ?? 0, price: value.price ?? 0, fee: value.fee ?? 0, note: value.note, account: account, investment: investment); item.id = value.id; item.tags = assignedTags; context.insert(item) } else { let item = Dividend(date: value.date, sequence: value.sequence, grossAmount: value.grossAmount ?? 0, withholdingTax: value.withholdingTax ?? 0, actualReceivedAmount: value.actualReceivedAmount, note: value.note, account: account, investment: investment); item.id = value.id; item.tags = assignedTags; context.insert(item) } }
        try context.save()
    }
}
