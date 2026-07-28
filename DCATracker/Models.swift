import Foundation
import SwiftData

enum CurrencyCode: String, Codable, CaseIterable { case usd = "USD", cny = "CNY" }

@Model
final class BrokerageAccount {
    @Attribute(.unique) var id: UUID
    var name: String
    var broker: String
    var note: String = ""
    var currencyCode: String
    var isArchived: Bool
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Purchase.account) var purchases: [Purchase]
    @Relationship(deleteRule: .cascade, inverse: \Sale.account) var sales: [Sale]
    @Relationship(deleteRule: .cascade, inverse: \Dividend.account) var dividends: [Dividend]

    init(name: String, broker: String = "", currency: CurrencyCode = .usd, isArchived: Bool = false, note: String = "") {
        id = UUID(); self.name = name; self.broker = broker; currencyCode = currency.rawValue
        self.isArchived = isArchived; self.note = note; createdAt = Date(); purchases = []; sales = []; dividends = []
    }
}

@Model
final class Investment {
    @Attribute(.unique) var id: UUID
    private var storedSymbol: String
    var symbol: String {
        get { storedSymbol }
        set { storedSymbol = newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    }
    var name: String
    var currencyCode: String
    var exchange: String = ""
    var latestPrice: Decimal?
    var previousClose: Decimal?
    var quoteUpdatedAt: Date?
    var isWatched: Bool = true
    var manualPrice: Decimal?
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Purchase.investment) var purchases: [Purchase]
    @Relationship(deleteRule: .cascade, inverse: \Sale.investment) var sales: [Sale]
    @Relationship(deleteRule: .cascade, inverse: \Dividend.investment) var dividends: [Dividend]

    init(symbol: String, name: String, currency: CurrencyCode = .usd, exchange: String = "", isWatched: Bool = true) {
        id = UUID(); storedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.name = name; currencyCode = currency.rawValue; self.exchange = exchange; self.isWatched = isWatched; createdAt = Date()
        purchases = []; sales = []; dividends = []
    }
}

@Model
final class Purchase {
    @Attribute(.unique) var id: UUID
    var date: Date
    var sequence: Int
    var quantity: Decimal
    var price: Decimal
    var fee: Decimal
    var note: String
    var account: BrokerageAccount?
    var investment: Investment?
    var tags: [TransactionTag] = []
    init(date: Date, sequence: Int = 0, quantity: Decimal, price: Decimal, fee: Decimal = 0,
         note: String = "", account: BrokerageAccount, investment: Investment) {
        id = UUID(); self.date = date; self.sequence = sequence; self.quantity = quantity
        self.price = price; self.fee = fee; self.note = note
        self.account = account; self.investment = investment
    }
}

@Model
final class Sale {
    @Attribute(.unique) var id: UUID
    var date: Date
    var sequence: Int
    var quantity: Decimal
    var price: Decimal
    var fee: Decimal
    var note: String
    var account: BrokerageAccount?
    var investment: Investment?
    var tags: [TransactionTag] = []
    init(date: Date, sequence: Int = 0, quantity: Decimal, price: Decimal, fee: Decimal = 0,
         note: String = "", account: BrokerageAccount, investment: Investment) {
        id = UUID(); self.date = date; self.sequence = sequence; self.quantity = quantity
        self.price = price; self.fee = fee; self.note = note
        self.account = account; self.investment = investment
    }
}

@Model
final class Dividend {
    @Attribute(.unique) var id: UUID
    var date: Date
    var sequence: Int
    var grossAmount: Decimal
    var withholdingTax: Decimal
    var actualReceivedAmount: Decimal?
    var note: String
    var account: BrokerageAccount?
    var investment: Investment?
    var tags: [TransactionTag] = []
    var receivedAmount: Decimal { actualReceivedAmount ?? (grossAmount - withholdingTax) }
    init(date: Date, sequence: Int = 0, grossAmount: Decimal, withholdingTax: Decimal = 0,
         actualReceivedAmount: Decimal? = nil, note: String = "", account: BrokerageAccount, investment: Investment) {
        id = UUID(); self.date = date; self.sequence = sequence; self.grossAmount = grossAmount
        self.withholdingTax = withholdingTax; self.actualReceivedAmount = actualReceivedAmount; self.note = note
        self.account = account; self.investment = investment
    }
}

@Model
final class TransactionTag {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    init(name: String, colorHex: String = "#4F46E5") { id = UUID(); self.name = name; self.colorHex = colorHex }
}

enum TransactionKind: String, CaseIterable { case purchase, sale, dividend }
struct TransactionFilter {
    static func matches(tags: [TransactionTag], selectedTagIDs: Set<UUID>) -> Bool {
        selectedTagIDs.isEmpty || tags.contains { selectedTagIDs.contains($0.id) }
    }
}
