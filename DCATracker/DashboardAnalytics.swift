import Foundation

struct HoldingSnapshot: Equatable, Identifiable {
    let investmentID: UUID
    let symbol: String
    let quantity: Decimal
    let price: Decimal
    let marketValue: Decimal
    let weight: Decimal
    var id: UUID { investmentID }
}

struct MonthlyContribution: Equatable, Identifiable {
    let month: Date
    let amount: Decimal
    var id: Date { month }
}

struct AccountHoldingSnapshot: Equatable, Identifiable {
    let accountID: UUID
    let accountName: String
    let marketValue: Decimal
    let weight: Decimal
    var id: UUID { accountID }
}

struct DashboardSnapshot: Equatable {
    let holdings: [HoldingSnapshot]
    let accountHoldings: [AccountHoldingSnapshot]
    let missingPriceSymbols: [String]
    let monthlyContributions: [MonthlyContribution]
    var marketValue: Decimal { holdings.reduce(0) { $0 + $1.marketValue } }
}

enum DashboardAnalytics {
    static func snapshot(investments: [Investment], purchases: [Purchase], sales: [Sale],
                         calendar: Calendar = .current) -> DashboardSnapshot {
        var valued: [(Investment, Decimal, Decimal)] = []
        var missing: [String] = []
        for investment in investments {
            let bought = purchases.lazy.filter { $0.investment?.id == investment.id }.reduce(0) { $0 + $1.quantity }
            let sold = sales.lazy.filter { $0.investment?.id == investment.id }.reduce(0) { $0 + $1.quantity }
            let quantity = bought - sold
            guard quantity > 0 else { continue }
            guard let price = investment.latestPrice ?? investment.manualPrice, price > 0 else {
                missing.append(investment.symbol); continue
            }
            valued.append((investment, quantity, price))
        }
        let total = valued.reduce(Decimal.zero) { $0 + $1.1 * $1.2 }
        let holdings = valued.map { investment, quantity, price in
            let value = quantity * price
            return HoldingSnapshot(investmentID: investment.id, symbol: investment.symbol, quantity: quantity,
                                   price: price, marketValue: value, weight: total > 0 ? value / total : 0)
        }.sorted { $0.symbol < $1.symbol }
        let prices = Dictionary(uniqueKeysWithValues: valued.map { ($0.0.id, $0.2) })
        let accounts = (purchases.compactMap(\.account) + sales.compactMap(\.account)).reduce(into: [UUID: BrokerageAccount]()) { result, account in
            result[account.id] = account
        }
        let accountValues = accounts.compactMap { id, account -> (BrokerageAccount, Decimal)? in
            let value = investments.reduce(Decimal.zero) { result, investment in
                guard let price = prices[investment.id] else { return result }
                let bought = purchases.lazy.filter { $0.account?.id == id && $0.investment?.id == investment.id }.reduce(0) { $0 + $1.quantity }
                let sold = sales.lazy.filter { $0.account?.id == id && $0.investment?.id == investment.id }.reduce(0) { $0 + $1.quantity }
                return result + max(bought - sold, 0) * price
            }
            return value > 0 ? (account, value) : nil
        }
        let accountTotal = accountValues.reduce(Decimal.zero) { $0 + $1.1 }
        let accountHoldings = accountValues.map { account, value in
            AccountHoldingSnapshot(accountID: account.id, accountName: account.name, marketValue: value,
                                   weight: accountTotal > 0 ? value / accountTotal : 0)
        }.sorted { $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending }
        let grouped = Dictionary(grouping: purchases) { purchase in
            calendar.date(from: calendar.dateComponents([.year, .month], from: purchase.date))!
        }
        let months = grouped.map { month, values in
            MonthlyContribution(month: month, amount: values.reduce(0) { $0 + $1.quantity * $1.price + $1.fee })
        }.sorted { $0.month < $1.month }
        return .init(holdings: holdings, accountHoldings: accountHoldings, missingPriceSymbols: missing.sorted(), monthlyContributions: months)
    }
}

enum USDFormat {
    static func string(_ value: Decimal, locale: Locale = Locale(identifier: "en_US")) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "\(formatter.string(from: value as NSDecimalNumber) ?? "0.00") $"
    }
}
