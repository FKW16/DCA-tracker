import Foundation

enum PriceSource: String, Sendable { case live, cache, manual }
struct AssetPlanInput: Sendable {
    let id: String; let weight: Decimal; let currentQuantity: Decimal
    let livePrice: Decimal?; let cachedPrice: Decimal?; let manualPrice: Decimal?
}
struct StrategyPlanInput: Sendable {
    let strategy: StrategyKind; let budget: BudgetKind; let periodIndex: Int
    let periodAmount: Decimal; let totalBudget: Decimal?; let totalPeriods: Int?
    let spentAmount: Decimal; let initialTargetValue: Decimal; let targetIncrement: Decimal
    let assets: [AssetPlanInput]
}
struct AssetSuggestion: Equatable, Sendable {
    let assetID: String; let amount: Decimal; let shares: Decimal; let price: Decimal
    let priceSource: PriceSource; let postTradeWeight: Decimal; let weightDeviation: Decimal; let reason: String
}
struct StrategySuggestion: Equatable, Sendable {
    let periodBudget: Decimal; let estimatedSpend: Decimal; let remainingCash: Decimal
    let targetValue: Decimal; let currentValue: Decimal; let strategyDifference: Decimal
    let assets: [AssetSuggestion]; let reason: String
}
enum StrategyError: Error, Equatable {
    case invalidPositiveValue, invalidWeights(total: Decimal), budgetExhausted, missingPrice(assetID: String), insufficientBudget
}

enum StrategyEngine {
    private static let weightTolerance = Decimal(string: "0.000001")!
    private static let exactCombinationLimit = 200_000
    private static let boundedStateLimit = 5_000

    static func suggest(_ input: StrategyPlanInput) -> Result<StrategySuggestion, StrategyError> {
        guard input.periodIndex > 0, input.periodAmount > 0, !input.assets.isEmpty,
              input.assets.allSatisfy({ $0.weight > 0 && $0.currentQuantity >= 0 }) else { return .failure(.invalidPositiveValue) }
        let totalWeight = input.assets.reduce(0) { $0 + $1.weight }
        guard abs(totalWeight - 1) <= weightTolerance else { return .failure(.invalidWeights(total: totalWeight)) }
        let normalized = input.assets.map { asset in
            AssetPlanInput(id: asset.id, weight: asset.weight / totalWeight, currentQuantity: asset.currentQuantity,
                           livePrice: asset.livePrice, cachedPrice: asset.cachedPrice, manualPrice: asset.manualPrice)
        }
        var priced: [(AssetPlanInput, Decimal, PriceSource)] = []
        for asset in normalized {
            if let value = asset.livePrice, value > 0 { priced.append((asset, value, .live)) }
            else if let value = asset.cachedPrice, value > 0 { priced.append((asset, value, .cache)) }
            else if let value = asset.manualPrice, value > 0 { priced.append((asset, value, .manual)) }
            else { return .failure(.missingPrice(assetID: asset.id)) }
        }
        let currentValue = priced.reduce(0) { $0 + $1.0.currentQuantity * $1.1 }
        var budget = input.periodAmount
        if input.budget == .fixed {
            guard let total = input.totalBudget, let periods = input.totalPeriods, total > 0, periods > 0 else { return .failure(.invalidPositiveValue) }
            let remaining = total - input.spentAmount
            guard remaining > 0 else { return .failure(.budgetExhausted) }
            budget = min(input.periodIndex == periods ? remaining : total / Decimal(periods), remaining)
        }
        guard priced.contains(where: { $0.1 <= budget }) else { return .failure(.insufficientBudget) }

        let optimized = optimize(priced: priced, budget: budget, currentValue: currentValue)
        let shares = optimized.shares, spent = optimized.spent
        let postTotal = currentValue + spent
        let suggestions = priced.indices.map { index in
            let item = priced[index], amount = Decimal(shares[index]) * item.1
            let postValue = item.0.currentQuantity * item.1 + amount
            let postWeight = postTotal > 0 ? postValue / postTotal : 0
            return AssetSuggestion(assetID: item.0.id, amount: amount, shares: Decimal(shares[index]), price: item.1,
                                   priceSource: item.2, postTradeWeight: postWeight,
                                   weightDeviation: abs(postWeight - item.0.weight),
                                   reason: shares[index] > 0 ? "整数股组合优化" : "本期不买入")
        }
        let target = input.periodAmount * Decimal(input.periodIndex)
        return .success(.init(periodBudget: budget, estimatedSpend: spent, remainingCash: budget - spent,
                              targetValue: target, currentValue: currentValue, strategyDifference: target - currentValue,
                              assets: suggestions, reason: "在不超预算下优化买后目标权重"))
    }

    private struct Candidate { let shares: [Int]; let spent: Decimal; let deviation: Decimal }

    private static func optimize(priced: [(AssetPlanInput, Decimal, PriceSource)], budget: Decimal, currentValue: Decimal) -> Candidate {
        let maxima = priced.map { affordableShareLimit(price: $0.1, budget: budget) }
        let combinations = maxima.reduce(1) { partial, maximum in
            partial > exactCombinationLimit / max(maximum + 1, 1) ? exactCombinationLimit + 1 : partial * (maximum + 1)
        }
        if combinations <= exactCombinationLimit {
            var best: Candidate?
            func visit(_ index: Int, _ shares: [Int], _ spent: Decimal) {
                if index == priced.count {
                    guard shares.contains(where: { $0 > 0 }) else { return }
                    let candidate = Candidate(shares: shares, spent: spent, deviation: deviation(priced: priced, shares: shares, currentValue: currentValue))
                    if best == nil || isBetter(candidate, than: best!, priced: priced, budget: budget) { best = candidate }; return
                }
                for count in 0...maxima[index] where spent + Decimal(count) * priced[index].1 <= budget {
                    visit(index + 1, shares + [count], spent + Decimal(count) * priced[index].1)
                }
            }
            visit(0, [], 0)
            if let best { return best }
            // The caller has already proved at least one asset is affordable. Decimal division can
            // still round a quotient just below one at extreme precision, so retain a safe fallback.
            let cheapest = priced.indices.min { priced[$0].1 < priced[$1].1 }!
            var shares = Array(repeating: 0, count: priced.count); shares[cheapest] = 1
            return Candidate(shares: shares, spent: priced[cheapest].1,
                             deviation: deviation(priced: priced, shares: shares, currentValue: currentValue))
        }
        // Large searches use a deterministic bounded dynamic-programming frontier. The cap is explicit and tested.
        var frontier = [Candidate(shares: [], spent: 0, deviation: 0)]
        for index in priced.indices {
            var next: [Candidate] = []
            for candidate in frontier {
                let maximum = affordableShareLimit(price: priced[index].1, budget: budget - candidate.spent)
                for count in 0...maximum {
                    let shares = candidate.shares + [count], spent = candidate.spent + Decimal(count) * priced[index].1
                    let padded = shares + Array(repeating: 0, count: priced.count - shares.count)
                    next.append(.init(shares: shares, spent: spent, deviation: deviation(priced: priced, shares: padded, currentValue: currentValue)))
                }
            }
            next.sort { isBetter($0, than: $1, priced: priced, budget: budget) }
            frontier = Array(next.prefix(boundedStateLimit))
        }
        return frontier.filter { $0.shares.contains(where: { $0 > 0 }) }.min { isBetter($0, than: $1, priced: priced, budget: budget) }!
    }

    private static func affordableShareLimit(price: Decimal, budget: Decimal) -> Int {
        guard price > 0, budget >= price else { return 0 }
        var result = NSDecimalNumber(decimal: budget / price).intValue
        while result > 0, Decimal(result) * price > budget { result -= 1 }
        while result < Int.max, Decimal(result + 1) * price <= budget { result += 1 }
        return result
    }

    private static func isBetter(_ lhs: Candidate, than rhs: Candidate, priced: [(AssetPlanInput, Decimal, PriceSource)], budget: Decimal) -> Bool {
        if lhs.deviation != rhs.deviation { return lhs.deviation < rhs.deviation }
        if budget - lhs.spent != budget - rhs.spent { return budget - lhs.spent < budget - rhs.spent }
        let order = priced.indices.sorted { priced[$0].0.id < priced[$1].0.id }
        return order.map { lhs.shares.indices.contains($0) ? lhs.shares[$0] : 0 }.lexicographicallyPrecedes(order.map { rhs.shares.indices.contains($0) ? rhs.shares[$0] : 0 })
    }

    private static func deviation(priced: [(AssetPlanInput, Decimal, PriceSource)], shares: [Int], currentValue: Decimal) -> Decimal {
        let spend = priced.indices.reduce(Decimal.zero) { $0 + Decimal(shares[$1]) * priced[$1].1 }
        let total = currentValue + spend
        guard total > 0 else { return .greatestFiniteMagnitude }
        return priced.indices.reduce(Decimal.zero) { result, index in
            let value = priced[index].0.currentQuantity * priced[index].1 + Decimal(shares[index]) * priced[index].1
            return result + abs(value / total - priced[index].0.weight)
        }
    }
}
