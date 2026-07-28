import Foundation

struct TransactionKey: Hashable, Sendable {
    let accountID: String
    let investmentID: String
}

enum LedgerEvent: Sendable {
    case buy(id: String, key: TransactionKey, date: Date, sequence: Int, quantity: Decimal, price: Decimal, fee: Decimal)
    case sell(id: String, key: TransactionKey, date: Date, sequence: Int, quantity: Decimal, price: Decimal, fee: Decimal)
    case dividend(id: String, key: TransactionKey, date: Date, sequence: Int, gross: Decimal, tax: Decimal)
}

enum CalculationError: Error, Equatable {
    case invalidAmount(eventID: String)
    case oversell(eventID: String, available: Decimal, requested: Decimal)
}

struct PositionResult: Equatable, Sendable {
    var quantity: Decimal = 0
    var costBasis: Decimal = 0
    var realizedGain: Decimal = 0
    var afterTaxDividends: Decimal = 0
    var averageCost: Decimal { quantity == 0 ? 0 : costBasis / quantity }
}

struct PortfolioResult: Equatable, Sendable {
    var positions: [TransactionKey: PositionResult]
    var quantity: Decimal { positions.values.reduce(0) { $0 + $1.quantity } }
    var costBasis: Decimal { positions.values.reduce(0) { $0 + $1.costBasis } }
    var realizedGain: Decimal { positions.values.reduce(0) { $0 + $1.realizedGain } }
    var afterTaxDividends: Decimal { positions.values.reduce(0) { $0 + $1.afterTaxDividends } }

    func totalReturn(marketValues: [TransactionKey: Decimal]) -> Decimal {
        let unrealized = positions.reduce(Decimal.zero) { partial, item in
            partial + (marketValues[item.key] ?? item.value.costBasis) - item.value.costBasis
        }
        return realizedGain + unrealized + afterTaxDividends
    }
}

enum InvestmentCalculator {
    static func dividendEvent(from dividend: Dividend, key: TransactionKey) -> LedgerEvent {
        .dividend(id: dividend.id.uuidString, key: key, date: dividend.date, sequence: dividend.sequence,
                  gross: dividend.receivedAmount, tax: 0)
    }
    static func replay(_ events: [LedgerEvent]) -> Result<PortfolioResult, CalculationError> {
        var positions: [TransactionKey: PositionResult] = [:]
        for event in events.sorted(by: orderedBefore) {
            let metadata = event.metadata
            var position = positions[metadata.key, default: PositionResult()]
            switch event {
            case let .buy(id, _, _, _, quantity, price, fee):
                guard quantity > 0, price >= 0, fee >= 0 else { return .failure(.invalidAmount(eventID: id)) }
                let amount = quantity * price + fee
                position.quantity += quantity; position.costBasis += amount
            case let .sell(id, _, _, _, quantity, price, fee):
                guard quantity > 0, price >= 0, fee >= 0 else { return .failure(.invalidAmount(eventID: id)) }
                guard quantity <= position.quantity else {
                    return .failure(.oversell(eventID: id, available: position.quantity, requested: quantity))
                }
                let proceeds = quantity * price - fee
                let removedCost = position.averageCost * quantity
                position.quantity -= quantity; position.costBasis -= removedCost; position.realizedGain += proceeds - removedCost
                if position.quantity == 0 { position.costBasis = 0 }
            case let .dividend(id, _, _, _, gross, tax):
                guard gross >= 0, tax >= 0, tax <= gross else { return .failure(.invalidAmount(eventID: id)) }
                position.afterTaxDividends += gross - tax
            }
            positions[metadata.key] = position
        }
        return .success(PortfolioResult(positions: positions))
    }

    private static func orderedBefore(_ lhs: LedgerEvent, _ rhs: LedgerEvent) -> Bool {
        let l = lhs.metadata, r = rhs.metadata
        if l.date != r.date { return l.date < r.date }
        if l.sequence != r.sequence { return l.sequence < r.sequence }
        return l.id < r.id
    }
}

private extension LedgerEvent {
    var metadata: (id: String, key: TransactionKey, date: Date, sequence: Int) {
        switch self {
        case let .buy(id, key, date, sequence, _, _, _), let .sell(id, key, date, sequence, _, _, _):
            (id, key, date, sequence)
        case let .dividend(id, key, date, sequence, _, _):
            (id, key, date, sequence)
        }
    }
}

struct DatedCashFlow: Sendable { let date: Date; let amount: Decimal }
enum XIRRResult: Equatable { case value(Decimal); case noSolution }

enum XIRRCalculator {
    static func calculate(_ cashFlows: [DatedCashFlow]) -> XIRRResult {
        guard cashFlows.count >= 2, cashFlows.contains(where: { $0.amount < 0 }), cashFlows.contains(where: { $0.amount > 0 }) else {
            return .noSolution
        }
        let sorted = cashFlows.sorted { $0.date < $1.date }
        let origin = sorted[0].date
        func npv(_ rate: Double) -> Double {
            sorted.reduce(0) { sum, flow in
                let years = flow.date.timeIntervalSince(origin) / (365.0 * 86_400.0)
                return sum + NSDecimalNumber(decimal: flow.amount).doubleValue / pow(1 + rate, years)
            }
        }
        var low = -0.999_999, high = 1.0
        var lowValue = npv(low), highValue = npv(high)
        while lowValue * highValue > 0, high < 1_000_000 {
            high *= 2; highValue = npv(high)
        }
        guard lowValue.isFinite, highValue.isFinite, lowValue * highValue <= 0 else { return .noSolution }
        for _ in 0..<200 {
            let middle = (low + high) / 2, value = npv(middle)
            if abs(value) < 1e-10 { return .value(Decimal(middle)) }
            if lowValue * value <= 0 { high = middle } else { low = middle; lowValue = value }
        }
        let answer = (low + high) / 2
        return answer.isFinite ? .value(Decimal(answer)) : .noSolution
    }
}
