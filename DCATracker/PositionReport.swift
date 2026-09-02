import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 单一持仓行:按「标的」维度聚合(不区分券商),反映当前实际持有仓位。
struct PositionHolding: Equatable, Identifiable {
    let investmentID: UUID
    let symbol: String
    let quantity: Decimal          // 当前持有股数(买入-卖出)
    let averageCost: Decimal       // 每股平均成本(含买入手续费)
    let totalCost: Decimal         // 平均成本 × 持有股数
    let currentPrice: Decimal?     // 当前价(latestPrice ?? manualPrice)
    let marketValue: Decimal       // 现值(需有效价格,否则为 0)
    let unrealizedPL: Decimal      // 浮动盈亏 = 现值 - 成本
    let changePercent: Decimal?    // 涨跌幅 =(当前价-平均成本)/平均成本
    var id: String { investmentID.uuidString }
    var hasValidPrice: Bool { currentPrice != nil }
}

enum PositionReportService {

    /// 计算全部持仓明细,按标的聚合(不区分券商)。
    static func holdings(investments: [Investment], purchases: [Purchase], sales: [Sale]) -> [PositionHolding] {
        var rows: [PositionHolding] = []
        for investment in investments {
            let buys = purchases.filter { $0.investment?.id == investment.id }
            let sells = sales.filter { $0.investment?.id == investment.id }
            let bought = buys.reduce(Decimal.zero) { $0 + $1.quantity }
            let sold = sells.reduce(Decimal.zero) { $0 + $1.quantity }
            let quantity = bought - sold
            guard quantity > 0 else { continue }
            let cost = buys.reduce(Decimal.zero) { $0 + $1.quantity * $1.price + $1.fee }
            let averageCost = bought > 0 ? cost / bought : 0
            let price = investment.latestPrice ?? investment.manualPrice
            let marketValue = (price != nil && price! > 0) ? quantity * price! : 0
            let totalCost = quantity * averageCost
            let change = (averageCost > 0 && price != nil && price! > 0) ? (price! - averageCost) / averageCost : nil
            rows.append(PositionHolding(investmentID: investment.id, symbol: investment.symbol,
                                        quantity: quantity, averageCost: averageCost, totalCost: totalCost,
                                        currentPrice: price, marketValue: marketValue,
                                        unrealizedPL: marketValue - totalCost, changePercent: change))
        }
        return rows.sorted { $0.symbol < $1.symbol }
    }

    /// 生成 Markdown 持仓报告,供外部 AI 或人工分析。
    static func markdown(holdings: [PositionHolding], invested: Decimal, marketValue: Decimal,
                         missingSymbols: [String], generatedAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("# DCA Tracker 持仓报告")
        lines.append("")
        lines.append("- 生成时间:\(formatter.string(from: generatedAt))")
        lines.append("- 币种:USD(美股)")
        lines.append("")
        lines.append("## 汇总")
        lines.append("")
        lines.append("| 指标 | 金额 |")
        lines.append("| --- | --- |")
        lines.append("| 累计投入 | \(USDFormat.string(invested)) |")
        lines.append("| 当前市值 | \(USDFormat.string(marketValue)) |")
        lines.append("| 浮动差额 | \(USDFormat.string(marketValue - invested)) |")
        lines.append("")
        lines.append("## 持有仓位")
        lines.append("")
        if holdings.isEmpty {
            lines.append("_暂无持仓_")
        } else {
            lines.append("| 标的 | 持有股数 | 平均成本 | 当前价 | 现值 | 浮动盈亏 | 涨跌幅 |")
            lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
            for item in holdings {
                let price = item.hasValidPrice ? USDFormat.string(item.currentPrice!) : "-"
                let value = item.hasValidPrice ? USDFormat.string(item.marketValue) : "-"
                let pl = item.hasValidPrice ? USDFormat.string(item.unrealizedPL) : "-"
                let change = item.changePercent.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "-"
                lines.append("| \(item.symbol) | \(item.quantity.formatted()) | \(USDFormat.string(item.averageCost)) | \(price) | \(value) | \(pl) | \(change) |")
            }
        }
        if !missingSymbols.isEmpty {
            lines.append("")
            lines.append("> 提示:以下标的存在持仓但缺少有效价格,未计入市值与涨跌幅:`\(missingSymbols.joined(separator: ", "))`")
        }
        lines.append("")
        lines.append("## 说明")
        lines.append("")
        lines.append("- 平均成本 = 累计买入金额(含手续费) ÷ 累计买入股数;卖出不影响平均成本。")
        lines.append("- 当前价优先使用最新行情,否则回退到手工价格。")
        lines.append("- 本报告由 DCA Tracker 自动生成,仅供分析参考,不构成投资建议。")
        return lines.joined(separator: "\n")
    }

    /// 自动同步写入固定路径:优先项目目录(便于外部 AI 直接读取),失败时回退 Application Support。
    static func writeAutoReport(_ text: String) -> URL? {
        let fallback: URL? = {
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
            return support.appendingPathComponent("DCA Tracker", isDirectory: true)
        }()
        let candidates: [URL] = [
            URL(fileURLWithPath: "/Users/wfk/develop/DCA-tracker", isDirectory: true),
            fallback
        ].compactMap { $0 }
        for directory in candidates {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("holdings-report.md")
            do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { continue }
        }
        return nil
    }
}
