import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selection: NavigationItem? = .overview
    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: $selection) { item in Label(item.title, systemImage: item.icon).tag(item) }
                .navigationTitle("DCA Tracker")
        } detail: {
            switch selection ?? .overview {
            case .overview: DashboardView()
            case .portfolios: PortfolioPlannerView()
            case .accounts: AccountsView()
            case .investments: InvestmentsView()
            case .transactions: TransactionLedgerView()
            case .settings: SettingsView()
            }
        }.frame(minWidth: 980, minHeight: 640)
    }
}

private enum NavigationItem: String, CaseIterable, Identifiable {
    case overview, portfolios, accounts, investments, transactions, settings
    var id: Self { self }
    var title: String { ["overview": "总览", "portfolios": "DCA 计划", "accounts": "券商账户", "investments": "投资标的", "transactions": "交易台账", "settings": "设置"][rawValue]! }
    var icon: String { ["overview": "chart.xyaxis.line", "portfolios": "calendar.badge.clock", "accounts": "building.columns", "investments": "briefcase", "transactions": "arrow.left.arrow.right", "settings": "gearshape"][rawValue]! }
}

extension Color {
    /// 嘉信理财风格主色:沉稳深蓝
    static let schwabBlue = Color(red: 0.00, green: 0.36, blue: 0.63)
    /// 图表分类配色:蓝灰色系,低饱和、简约
    static let schwabPalette: [Color] = [
        Color(red: 0.00, green: 0.36, blue: 0.63),   // 深蓝
        Color(red: 0.24, green: 0.52, blue: 0.76),   // 中蓝
        Color(red: 0.50, green: 0.69, blue: 0.85),   // 浅蓝
        Color(red: 0.37, green: 0.46, blue: 0.53),   // 石板灰
        Color(red: 0.66, green: 0.73, blue: 0.79),   // 浅灰蓝
        Color(red: 0.24, green: 0.60, blue: 0.62),   // 青
        Color(red: 0.84, green: 0.65, blue: 0.32),   // 暖金(点缀)
    ]
}

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query private var investments: [Investment]
    @Query private var purchases: [Purchase]
    @Query private var sales: [Sale]
    @State private var refreshing = false; @State private var quoteStatus = ""
    @State private var holdings: [PositionHolding] = []
    @AppStorage("dashboardHoldingOrder") private var holdingOrder = ""
    @State private var exporting = false; @State private var document = ExportDocument(); @State private var exportName = "DCA-Tracker-holdings-report"; @State private var autoReportPath = ""
    private let coordinator = QuoteCoordinator(source: TwelveDataSource())
    private var snapshot: DashboardSnapshot { DashboardAnalytics.snapshot(investments: investments, purchases: purchases, sales: sales) }
    private var invested: Decimal { purchases.reduce(0) { $0 + $1.quantity * $1.price + $1.fee } }
    private var marketValue: Decimal { snapshot.marketValue }
    private var displayHoldings: [PositionHolding] {
        let saved = holdingOrder.split(separator: ",").map(String.init)
        var rank: [String: Int] = [:]
        for (index, symbol) in saved.enumerated() { rank[symbol] = index }
        return holdings.sorted { (rank[$0.symbol] ?? Int.max, $0.symbol) < (rank[$1.symbol] ?? Int.max, $1.symbol) }
    }
    /// 持仓市值结构:按市值降序(扇区与图例从大到小,配色与顺序对应)
    private var holdingsByValue: [HoldingSnapshot] { snapshot.holdings.sorted { $0.marketValue > $1.marketValue } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("投资总览").font(.largeTitle.bold())
                Spacer()
                Button { syncReport(); exporting = true } label: { Label("导出持仓报告", systemImage: "doc.text") }
                    .buttonStyle(.bordered)
                Button { Task { await refresh() } } label: { Label("刷新行情", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .tint(.schwabBlue)
                    .disabled(refreshing)
            }
            if !quoteStatus.isEmpty { Text(quoteStatus).font(.caption).foregroundStyle(.secondary) }
            if !autoReportPath.isEmpty { Label("报告已自动同步：\(autoReportPath)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            HStack { MetricCard(title: "累计投入", value: invested); MetricCard(title: "当前市值", value: marketValue); MetricCard(title: "浮动差额", value: marketValue - invested) }
            if investments.isEmpty { ContentUnavailableView("还没有投资标的", systemImage: "chart.pie", description: Text("请先添加账户和标的，再到交易台账手动新增记录。")) } else {
                GroupBox("持有仓位") {
                    if holdings.isEmpty {
                        ContentUnavailableView("暂无持仓", systemImage: "tray", description: Text("录入买入记录后，这里会展示当前持有仓位。"))
                    } else {
                        let total = displayHoldings.reduce(Decimal.zero) { $0 + $1.marketValue }
                        VStack(spacing: 0) {
                            List {
                                HStack {
                                    Text("标的").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("股数").frame(maxWidth: .infinity, alignment: .trailing)
                                    Text("现价").frame(maxWidth: .infinity, alignment: .trailing)
                                    Text("平均成本").frame(maxWidth: .infinity, alignment: .trailing)
                                    Text("现值").frame(maxWidth: .infinity, alignment: .trailing)
                                    Text("比例").frame(width: 56, alignment: .trailing)
                                    Text("涨/跌幅").frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                .moveDisabled(true)
                                ForEach(displayHoldings) { item in
                                    HStack {
                                        Text(item.symbol).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(item.quantity.formatted(.number.precision(.fractionLength(0...6))))").frame(maxWidth: .infinity, alignment: .trailing)
                                        Text(item.hasValidPrice ? USDFormat.string(item.currentPrice!) : "—").frame(maxWidth: .infinity, alignment: .trailing)
                                        Text(USDFormat.string(item.averageCost)).frame(maxWidth: .infinity, alignment: .trailing)
                                        Text(item.hasValidPrice ? USDFormat.string(item.marketValue) : "—").frame(maxWidth: .infinity, alignment: .trailing)
                                        Text(item.hasValidPrice && total > 0 ? (item.marketValue / total).formatted(.percent.precision(.fractionLength(1))) : "—")
                                            .frame(width: 56, alignment: .trailing)
                                            .foregroundStyle(.secondary)
                                        Text(item.changePercent.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "—")
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                            .foregroundStyle(item.changePercent.map { $0 >= 0 ? Color.red : Color.green } ?? .secondary)
                                    }
                                    .font(.body.monospacedDigit())
                                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                                }
                                .onMove(perform: moveHolding)
                            }
                            .listStyle(.plain)
                            .frame(height: min(max(84, 30 + CGFloat(displayHoldings.count) * 24), 230))
                            .scrollContentBackground(.hidden)
                        }
                    }
                }
                GroupBox("持仓市值结构") { VStack(alignment: .leading, spacing: 12) { Chart(holdingsByValue) { item in SectorMark(angle: .value("市值", NSDecimalNumber(decimal: item.marketValue).doubleValue), innerRadius: .ratio(0.62), angularInset: 1.5).foregroundStyle(by: .value("代码", item.symbol)).cornerRadius(3) }.chartForegroundStyleScale(range: Color.schwabPalette).chartLegend(.hidden).frame(height: 220); VStack(spacing: 6) { ForEach(Array(holdingsByValue.enumerated()), id: \.element.id) { index, item in HStack(spacing: 8) { Circle().fill(Color.schwabPalette[index % Color.schwabPalette.count]).frame(width: 8, height: 8); Text(item.symbol); Spacer(); Text(USDFormat.string(item.marketValue)).monospacedDigit(); Text(item.weight, format: .percent.precision(.fractionLength(1))).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing) } } }; if !snapshot.missingPriceSymbols.isEmpty { Label("缺少有效价格，已排除：\(snapshot.missingPriceSymbols.joined(separator: ", "))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } } }
                GroupBox("月度投入") { Chart(snapshot.monthlyContributions) { BarMark(x: .value("月份", $0.month, unit: .month), y: .value("投入", NSDecimalNumber(decimal: $0.amount).doubleValue)).foregroundStyle(Color.schwabBlue).cornerRadius(3) }.chartXAxis { AxisMarks(values: .stride(by: .month)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.year().month(.abbreviated)) } }.frame(height: 180) }
                GroupBox("券商账户持仓") {
                    if snapshot.accountHoldings.isEmpty {
                        ContentUnavailableView("暂无账户持仓", systemImage: "chart.pie", description: Text("录入买入记录并设置有效价格后显示。"))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Chart(snapshot.accountHoldings) { item in
                                SectorMark(angle: .value("市值", NSDecimalNumber(decimal: item.marketValue).doubleValue), innerRadius: .ratio(0.62), angularInset: 1.5)
                                    .foregroundStyle(by: .value("账户", item.accountName)).cornerRadius(3)
                            }.chartForegroundStyleScale(range: Color.schwabPalette).chartLegend(.hidden).frame(height: 220)
                            VStack(spacing: 6) { ForEach(Array(snapshot.accountHoldings.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 8) { Circle().fill(Color.schwabPalette[index % Color.schwabPalette.count]).frame(width: 8, height: 8); Text(item.accountName); Spacer(); Text(USDFormat.string(item.marketValue)).monospacedDigit(); Text(item.weight, format: .percent.precision(.fractionLength(1))).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing) }
                            } }
                        }
                    }
                }
            }
        }.padding(24) }.task { syncReport() }
      .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: exportName) { _ in }
    }
    @MainActor private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        await refreshQuotes()
        syncReport()
    }
    private func syncReport() {
        holdings = PositionReportService.holdings(investments: investments, purchases: purchases, sales: sales)
        let text = PositionReportService.markdown(holdings: displayHoldings, invested: invested, marketValue: marketValue, missingSymbols: snapshot.missingPriceSymbols)
        document = ExportDocument(data: Data(text.utf8))
        autoReportPath = PositionReportService.writeAutoReport(text)?.path ?? ""
    }
    private func moveHolding(from source: IndexSet, to destination: Int) {
        var items = displayHoldings
        items.move(fromOffsets: source, toOffset: destination)
        holdingOrder = items.map(\.symbol).joined(separator: ",")
    }
    @MainActor private func refreshQuotes() async {
        guard let key = try? KeychainAPIKeyStore().read(), !key.isEmpty else { quoteStatus = "保存 Twelve Data Key 后可刷新行情"; return }
        var success = 0; var failures: [String] = []
        for item in investments where item.isWatched { do { let quote = try await coordinator.quote(symbol: item.symbol, apiKey: key); item.latestPrice = quote.price; item.previousClose = quote.previousClose; item.quoteUpdatedAt = quote.timestamp; success += 1 } catch { failures.append("\(item.symbol): \(error.localizedDescription)") } }
        if success > 0 { try? context.save() }; quoteStatus = failures.isEmpty ? "已更新 \(success) 个标的行情" : "更新 \(success) 个；失败：\(failures.joined(separator: "，"))"
    }
}

struct MetricCard: View {
    let title: String; let value: Decimal
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(USDFormat.string(value))
                .font(.title2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct PortfolioPlannerView: View {
    @Environment(\.modelContext) private var context
    @Query private var portfolios: [InvestmentPortfolio]; @Query private var investments: [Investment]; @Query private var accounts: [BrokerageAccount]; @Query private var purchases: [Purchase]; @Query private var sales: [Sale]
    @State private var amount: Decimal = 1000; @State private var suggestion: StrategySuggestion?; @State private var error = ""
    @State private var enabledIDs: Set<UUID> = []; @State private var weights: [UUID: Decimal] = [:]
    var body: some View { Form {
        Section { TextField("月度新增资金（美元）", value: $amount, format: .number); ForEach(investments) { investment in HStack { Toggle(investment.symbol, isOn: enabledBinding(investment.id)); Spacer(); TextField("目标比例", value: weightBinding(investment.id), format: .percent).frame(width: 120).disabled(!enabledIDs.contains(investment.id)) } }; Text("修改后自动保存。启用标的权重必须为正且合计 100%。").font(.caption).foregroundStyle(.secondary) }
        Section("本期建议") {
            if portfolios.isEmpty { Text("请先添加标的并创建 DCA 计划。") } else {
                Button("生成本期建议") { calculate() }
                if let suggestion { HStack(spacing: 12) { MetricCard(title: "预计花费", value: suggestion.estimatedSpend); MetricCard(title: "剩余现金", value: suggestion.remainingCash); MetricCard(title: "当前市值", value: suggestion.currentValue) }; ForEach(suggestion.assets, id: \.assetID) { item in HStack { Text(investments.first(where: { $0.id.uuidString == item.assetID })?.symbol ?? item.assetID); Spacer(); Text("\(Int(truncating: item.shares as NSDecimalNumber)) 股 · \(USDFormat.string(item.amount))"); Text("买后 \(item.postTradeWeight.formatted(.percent.precision(.fractionLength(1))))").foregroundStyle(.secondary) } }; Button("确认记为买入") { confirm(suggestion) }.disabled(accounts.isEmpty || suggestion.estimatedSpend <= 0) }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
        }
    }.formStyle(.grouped).navigationTitle("DCA 计划").task { loadPlan() }
      .onChange(of: amount) { _, _ in savePlanIfValid() }
      .onChange(of: enabledIDs) { _, _ in savePlanIfValid() }
      .onChange(of: weights) { _, _ in savePlanIfValid() } }
    private func loadPlan() { if let portfolio = portfolios.sorted(by: { $0.createdAt < $1.createdAt }).first, let plan = portfolio.plans.sorted(by: { $0.startDate < $1.startDate }).first { amount = plan.periodAmount; enabledIDs = Set(portfolio.assets.compactMap { $0.investment?.id }); weights = Dictionary(uniqueKeysWithValues: portfolio.assets.compactMap { asset in asset.investment.map { ($0.id, asset.targetWeight) } }) } else { enabledIDs = Set(investments.map(\.id)); let equal = investments.isEmpty ? 0 : Decimal(1) / Decimal(investments.count); weights = Dictionary(uniqueKeysWithValues: investments.map { ($0.id, equal) }) } }
    private func savePlanIfValid() {
        guard amount > 0, case .success = SinglePlanCoordinator.validateWeights(weights, enabledIDs: enabledIDs) else { return }
        do {
            _ = try SinglePlanCoordinator.save(monthlyAmount: amount, investments: investments, enabledIDs: enabledIDs, weights: weights, portfolios: portfolios, context: context)
            error = ""
        } catch let saveError {
            error = String(describing: saveError)
        }
    }
    private func enabledBinding(_ id: UUID) -> Binding<Bool> { .init(get: { enabledIDs.contains(id) }, set: { if $0 { enabledIDs.insert(id); if weights[id] == nil { weights[id] = 0 } } else { enabledIDs.remove(id) } }) }
    private func weightBinding(_ id: UUID) -> Binding<Decimal> { .init(get: { weights[id] ?? 0 }, set: { weights[id] = $0 }) }
    private func calculate() {
        suggestion = nil
        guard amount > 0 else { error = "月度新增资金必须大于 0。"; return }
        switch SinglePlanCoordinator.validateWeights(weights, enabledIDs: enabledIDs) {
        case .failure(.invalidPositiveValue):
            error = "请至少启用一个标的，并确保所有启用标的的目标比例都大于 0。"
            return
        case .failure(.invalidWeights(let total)):
            error = "目标比例合计必须为 100%，当前为 \(total.formatted(.percent.precision(.fractionLength(0...2))))。"
            return
        case .failure(let validationError):
            error = String(describing: validationError)
            return
        case .success:
            break
        }
        do {
            let plan = try SinglePlanCoordinator.save(monthlyAmount: amount, investments: investments, enabledIDs: enabledIDs, weights: weights, portfolios: portfolios, context: context)
            guard let portfolio = plan.portfolio else { error = "DCA 计划暂不可用。"; return }
            switch StrategyEngine.suggest(PlanningWorkflow.input(plan: plan, portfolio: portfolio, purchases: purchases, sales: sales)) {
            case .success(let value): suggestion = value; error = ""
            case .failure(let value): error = String(describing: value)
            }
        } catch let calculationError {
            error = String(describing: calculationError)
        }
    }
    private func confirm(_ value: StrategySuggestion) { guard let p = portfolios.first, let plan = p.plans.first, let account = accounts.first else { error = "请先添加券商账户"; return }; _ = PlanningWorkflow.confirm(value, plan: plan, portfolio: p, account: account, context: context); try? context.save(); suggestion = nil }
}

struct AccountsView: View {
    @Environment(\.modelContext) private var context; @Query private var accounts: [BrokerageAccount]
    @State private var name = ""; @State private var editing: BrokerageAccount?
    var body: some View { Form { Section("新增账户") { TextField("名称", text: $name); Button("添加") { context.insert(BrokerageAccount(name: name)); try? context.save(); name = "" }.disabled(name.isEmpty) }; Section("账户") { ForEach(accounts) { account in HStack { VStack(alignment: .leading) { Text(account.name); if !account.broker.isEmpty { Text(account.broker).foregroundStyle(.secondary) } }; Spacer(); Button("编辑") { editing = account } } } } }.formStyle(.grouped).navigationTitle("券商账户").sheet(item: $editing) { account in AccountEditSheet(account: account) { name, broker, note, archived in account.name = name; account.broker = broker; account.note = note; account.isArchived = archived; try? context.save(); editing = nil } } }
}

struct InvestmentsView: View {
    @Environment(\.modelContext) private var context; @Query private var investments: [Investment]; @Query private var assets: [PortfolioAsset]
    @State private var symbol = ""; @State private var manual: Decimal?; @State private var status = ""; @State private var editing: Investment?; @State private var pendingDelete: Investment?
    private let coordinator = QuoteCoordinator(source: TwelveDataSource())
    var body: some View { Form {
        Section("新增标的") { TextField("代码", text: $symbol); TextField("手工价格（美元，可选）", value: $manual, format: .number); Button("添加") { let item = Investment(symbol: symbol, name: symbol); item.manualPrice = manual; context.insert(item); try? context.save(); symbol = ""; manual = nil }.disabled(symbol.isEmpty); Button("刷新全部关注标的") { Task { await refresh() } }; Text(status).font(.caption).foregroundStyle(.secondary) }
        Section("行情（自动→缓存→手工）") { ForEach(investments) { item in HStack { VStack(alignment: .leading) { Text(item.symbol).font(.headline); Text(item.quoteUpdatedAt.map { "更新：\($0.formatted())" } ?? "尚无自动行情").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(USDFormat.string(item.latestPrice ?? item.manualPrice ?? 0)); Button("编辑") { editing = item }; Button("删除", role: .destructive) { pendingDelete = item } } } }
    }.formStyle(.grouped).navigationTitle("投资标的").task { await refresh() }
      .sheet(item: $editing) { item in InvestmentEditSheet(investment: item) { name, exchange, manual, watched in item.name = name; item.exchange = exchange; item.manualPrice = manual; item.isWatched = watched; try? context.save(); editing = nil } }
      .confirmationDialog("确定删除 \(pendingDelete?.symbol ?? "")？", isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
          Button("删除标的及相关记录", role: .destructive) { if let item = pendingDelete { delete(item) }; pendingDelete = nil }
          Button("取消", role: .cancel) {}
      } message: { Text("该标的的买入、卖出、股息记录以及 DCA 计划配置也会被删除，此操作无法撤销。") } }
    private func delete(_ investment: Investment) {
        let symbol = investment.symbol
        do { try InvestmentDeletionService.delete(investment, portfolioAssets: assets, context: context); status = "已删除 \(symbol)" }
        catch { status = "删除失败：\(error.localizedDescription)" }
    }
    @MainActor private func refresh() async {
        guard let key = try? KeychainAPIKeyStore().read(), !key.isEmpty else { status = "请先在设置中保存 Twelve Data API Key"; return }
        var success = 0; var failures: [String] = []
        for item in investments where item.isWatched { do { let quote = try await coordinator.quote(symbol: item.symbol, apiKey: key); item.latestPrice = quote.price; item.previousClose = quote.previousClose; item.quoteUpdatedAt = quote.timestamp; success += 1 } catch { failures.append("\(item.symbol): \(error.localizedDescription)") } }
        if success > 0 { try? context.save() }; status = failures.isEmpty ? "已更新 \(success) 个标的" : "更新 \(success) 个；失败：\(failures.joined(separator: "，"))"
    }
}

struct TransactionLedgerView: View {
    @Environment(\.modelContext) private var context
    @Query private var purchases: [Purchase]; @Query private var sales: [Sale]; @Query private var dividends: [Dividend]; @Query private var tags: [TransactionTag]; @Query private var accounts: [BrokerageAccount]; @Query private var investments: [Investment]; @Query private var portfolios: [InvestmentPortfolio]; @Query private var assets: [PortfolioAsset]; @Query private var plans: [InvestmentPlan]; @Query private var executions: [PlanExecution]
    @State private var selectedType = "all"; @State private var selectedTagIDs: Set<UUID> = []; @State private var selectedRecordIDs: Set<UUID> = []; @State private var exporting = false; @State private var document = ExportDocument(); @State private var exportType = UTType.json; @State private var exportName = "DCA-Tracker"; @State private var message = ""; @State private var pendingDelete: LedgerRecord?; @State private var confirmingBatchDelete = false; @State private var editing: LedgerRecord?; @State private var adding = false
    private var records: [LedgerRecord] {
        let buys = selectedType == "all" || selectedType == "buy" ? purchases.compactMap(buyRecord) : []
        let sells = selectedType == "all" || selectedType == "sell" ? sales.compactMap(saleRecord) : []
        let income = selectedType == "all" || selectedType == "dividend" ? dividends.compactMap(dividendRecord) : []
        return (buys + sells + income).sorted { $0.date > $1.date }
    }
    var body: some View { VStack {
        HStack { Button("新增投资记录", systemImage: "plus") { adding = true }.buttonStyle(.borderedProminent).disabled(accounts.isEmpty || investments.isEmpty); Picker("类型", selection: $selectedType) { Text("全部").tag("all"); Text("买入").tag("buy"); Text("卖出").tag("sell"); Text("股息").tag("dividend") }.frame(width: 180); Button(selectedRecordIDs.count == records.count && !records.isEmpty ? "取消全选" : "全选") { toggleSelectAll() }.disabled(records.isEmpty); Spacer(); Button("导出选中") { exportSelected() }.disabled(selectedRecordIDs.isEmpty); Button("删除选中", role: .destructive) { confirmingBatchDelete = true }.disabled(selectedRecordIDs.isEmpty); Button("导出 CSV") { exportCSV(records, name: "DCA-Tracker-ledger") }; Button("导出完整 JSON") { exportBackup() } }.padding()
        if accounts.isEmpty || investments.isEmpty { ContentUnavailableView("先完成基础设置", systemImage: "tray", description: Text("请先添加至少一个券商账户和投资标的。")) } else if records.isEmpty { ContentUnavailableView("还没有投资记录", systemImage: "list.bullet.rectangle", description: Text("点击左上角“新增投资记录”手动录入买入、卖出或股息。")) } else { Table(records, selection: $selectedRecordIDs) { TableColumn("类型", value: \.type); TableColumn("日期") { Text($0.date, format: .dateTime.year().month().day()) }; TableColumn("标的", value: \.symbol); TableColumn("数量") { record in Text(record.quantity.map { "\($0.formatted(.number.precision(.fractionLength(0...6)))) 股" } ?? "—") }; TableColumn("账户", value: \.account); TableColumn("金额") { Text(USDFormat.string($0.amount)) }; TableColumn("操作") { record in HStack { Button("编辑") { editing = record }; Button("删除", role: .destructive) { pendingDelete = record } } } } }
        if !message.isEmpty { Text(message).foregroundStyle(message.contains("失败") ? .red : .secondary).padding() }
    }.navigationTitle("交易台账")
      .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { message = $0.isSuccess ? "导出成功" : "导出失败" }
      .sheet(isPresented: $adding) { TransactionEntrySheet(accounts: accounts.filter { !$0.isArchived }, investments: investments) { draft in add(draft) } }
      .sheet(item: $editing) { record in TransactionEditSheet(record: record, accounts: editAccounts(for: record)) { account, date, first, second, fee, note in applyEdit(record, account: account, date: date, first: first, second: second, fee: fee, note: note); editing = nil } }
      .confirmationDialog("确定删除这笔交易？", isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) { Button("删除", role: .destructive) { if let record = pendingDelete { delete(record) }; pendingDelete = nil }; Button("取消", role: .cancel) {} }
      .confirmationDialog("确定删除选中的 \(selectedRecordIDs.count) 笔交易？", isPresented: $confirmingBatchDelete) { Button("删除选中交易", role: .destructive) { deleteSelected() }; Button("取消", role: .cancel) {} } message: { Text("此操作无法撤销。") }
      .onChange(of: selectedType) { _, _ in selectedRecordIDs.formIntersection(Set(records.map(\.id))) }
    }
    private func buyRecord(_ value: Purchase) -> LedgerRecord? { guard TransactionFilter.matches(tags: value.tags, selectedTagIDs: selectedTagIDs) else { return nil }; return .init(id: value.id, type: "买入", date: value.date, symbol: value.investment?.symbol ?? "", account: value.account?.name ?? "", accountID: value.account?.id, quantity: value.quantity, price: value.price, amount: value.quantity * value.price + value.fee, tags: value.tags.map(\.name), note: value.note) }
    private func saleRecord(_ value: Sale) -> LedgerRecord? { guard TransactionFilter.matches(tags: value.tags, selectedTagIDs: selectedTagIDs) else { return nil }; return .init(id: value.id, type: "卖出", date: value.date, symbol: value.investment?.symbol ?? "", account: value.account?.name ?? "", accountID: value.account?.id, quantity: value.quantity, price: value.price, amount: value.quantity * value.price - value.fee, tags: value.tags.map(\.name), note: value.note) }
    private func dividendRecord(_ value: Dividend) -> LedgerRecord? { guard TransactionFilter.matches(tags: value.tags, selectedTagIDs: selectedTagIDs) else { return nil }; return .init(id: value.id, type: "股息", date: value.date, symbol: value.investment?.symbol ?? "", account: value.account?.name ?? "", accountID: value.account?.id, quantity: nil, price: nil, amount: value.receivedAmount, tags: value.tags.map(\.name), note: value.note) }
    private func add(_ draft: TransactionDraft) { guard draft.first > 0, draft.second >= 0, draft.fee >= 0 else { message = "保存失败：请输入有效数字"; return }; switch draft.kind { case .buy: context.insert(Purchase(date: draft.date, quantity: draft.first, price: draft.second, fee: draft.fee, note: draft.note, account: draft.account, investment: draft.investment)); case .sell: let held = purchases.filter { $0.account?.id == draft.account.id && $0.investment?.id == draft.investment.id }.reduce(0) { $0 + $1.quantity } - sales.filter { $0.account?.id == draft.account.id && $0.investment?.id == draft.investment.id }.reduce(0) { $0 + $1.quantity }; guard draft.first <= held else { message = "保存失败：可卖数量仅 \(held)"; return }; context.insert(Sale(date: draft.date, quantity: draft.first, price: draft.second, fee: draft.fee, note: draft.note, account: draft.account, investment: draft.investment)); case .dividend: guard draft.second <= draft.first else { message = "保存失败：预扣税不能超过税前股息"; return }; context.insert(Dividend(date: draft.date, grossAmount: draft.first, withholdingTax: draft.second, actualReceivedAmount: draft.fee, note: draft.note, account: draft.account, investment: draft.investment)) }; do { try context.save(); adding = false; message = "记录已保存" } catch { message = "保存失败：\(error.localizedDescription)" } }
    private func delete(_ record: LedgerRecord) { delete(ids: [record.id]); selectedRecordIDs.remove(record.id) }
    private func delete(ids: Set<UUID>) { purchases.filter { ids.contains($0.id) }.forEach { context.delete($0) }; sales.filter { ids.contains($0.id) }.forEach { context.delete($0) }; dividends.filter { ids.contains($0.id) }.forEach { context.delete($0) }; do { try context.save(); message = "已删除 \(ids.count) 笔交易" } catch { message = "删除失败：\(error.localizedDescription)" } }
    private func deleteSelected() { let ids = selectedRecordIDs; delete(ids: ids); selectedRecordIDs.subtract(ids) }
    private func toggleSelectAll() { let visible = Set(records.map(\.id)); if !visible.isEmpty, visible.isSubset(of: selectedRecordIDs) { selectedRecordIDs.subtract(visible) } else { selectedRecordIDs.formUnion(visible) } }
    private func exportCSV(_ values: [LedgerRecord], name: String) { document = .init(data: ExportService.csv(values)); exportType = .commaSeparatedText; exportName = name; exporting = true }
    private func exportSelected() { exportCSV(records.filter { selectedRecordIDs.contains($0.id) }, name: "DCA-Tracker-selected-ledger") }
    private func applyEdit(_ record: LedgerRecord, account: BrokerageAccount, date: Date, first: Decimal, second: Decimal, fee: Decimal, note: String) { guard first >= 0, second >= 0, fee >= 0 else { return }; if let value = purchases.first(where: { $0.id == record.id }) { value.date = date; value.quantity = first; value.price = second; value.fee = fee; value.note = note; value.account = account }; if let value = sales.first(where: { $0.id == record.id }) { value.date = date; value.quantity = first; value.price = second; value.fee = fee; value.note = note; value.account = account }; if let value = dividends.first(where: { $0.id == record.id }) { value.date = date; value.grossAmount = first; value.withholdingTax = second; value.actualReceivedAmount = fee; value.note = note; value.account = account }; try? context.save() }
    private func editAccounts(for record: LedgerRecord) -> [BrokerageAccount] { var result = accounts.filter { !$0.isArchived }; if let current = accounts.first(where: { $0.id == record.accountID }), !result.contains(where: { $0.id == current.id }) { result.insert(current, at: 0) }; return result }
    private var graph: BackupGraph { .init(accounts: accounts, investments: investments, tags: tags, purchases: purchases, sales: sales, dividends: dividends, portfolios: portfolios, assets: assets, plans: plans, executions: executions) }
    private func exportBackup() { if let data = try? FullBackupService.encode(FullBackupService.capture(graph)) { document = .init(data: data); exportType = .json; exportName = "DCA-Tracker-complete-backup"; exporting = true } }
}

enum TransactionDraftKind: String, CaseIterable, Identifiable { case buy = "买入", sell = "卖出", dividend = "股息"; var id: Self { self } }
struct TransactionDraft { let kind: TransactionDraftKind; let account: BrokerageAccount; let investment: Investment; let date: Date; let first, second, fee: Decimal; let note: String }

struct TransactionEntrySheet: View {
    let accounts: [BrokerageAccount]; let investments: [Investment]; let onSave: (TransactionDraft) -> Void
    @Environment(\.dismiss) private var dismiss; @State private var kind = TransactionDraftKind.buy; @State private var accountID: UUID; @State private var investmentID: UUID; @State private var date = Date(); @State private var first: Decimal = 0; @State private var second: Decimal = 0; @State private var fee: Decimal = 0; @State private var note = ""; @State private var buyByAmount = true; @State private var amountUSD: Decimal = 0
    init(accounts: [BrokerageAccount], investments: [Investment], onSave: @escaping (TransactionDraft) -> Void) { self.accounts = accounts; self.investments = investments; self.onSave = onSave; let preferred = accounts.first { $0.name.localizedCaseInsensitiveContains("嘉信") || $0.name.localizedCaseInsensitiveContains("schwab") || $0.name.localizedCaseInsensitiveContains("charles") }; _accountID = State(initialValue: preferred?.id ?? accounts.first!.id); _investmentID = State(initialValue: investments.first!.id) }
    private var derivedShares: Decimal { buyByAmount && second > 0 ? amountUSD / second : first }
    var body: some View { Form {
        Picker("类型", selection: $kind) { ForEach(TransactionDraftKind.allCases) { Text($0.rawValue).tag($0) } }
        Picker("账户", selection: $accountID) { ForEach(accounts) { Text($0.name).tag($0.id) } }
        Picker("标的", selection: $investmentID) { ForEach(investments) { Text($0.symbol).tag($0.id) } }
        DatePicker("日期", selection: $date, displayedComponents: .date)
        if kind == .buy {
            Picker("买入方式", selection: $buyByAmount) { Text("按金额（美元）").tag(true); Text("按股数").tag(false) }
            if buyByAmount {
                TextField("购买金额（美元）", value: $amountUSD, format: .number)
                TextField("购入价（美元/股）", value: $second, format: .number)
                if second > 0 { Text("约 \(derivedShares.formatted(.number.precision(.fractionLength(0...6)))) 股").font(.caption).foregroundStyle(.secondary) }
            } else {
                TextField("股数", value: $first, format: .number)
                TextField("购入价（美元/股）", value: $second, format: .number)
            }
            TextField("手续费（美元）", value: $fee, format: .number)
        } else if kind == .sell {
            TextField("股数", value: $first, format: .number); TextField("卖出价（美元/股）", value: $second, format: .number); TextField("手续费（美元）", value: $fee, format: .number)
        } else {
            TextField("税前股息", value: $first, format: .number); TextField("预扣税", value: $second, format: .number); TextField("实际到账", value: $fee, format: .number)
        }
        TextField("备注", text: $note)
        HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { guard let account = accounts.first(where: { $0.id == accountID }), let investment = investments.first(where: { $0.id == investmentID }) else { return }; onSave(.init(kind: kind, account: account, investment: investment, date: date, first: derivedShares, second: second, fee: fee, note: note)) }.buttonStyle(.borderedProminent).disabled((buyByAmount && kind == .buy ? amountUSD <= 0 : first <= 0) || second < 0 || fee < 0) }
    }.formStyle(.grouped).padding().frame(width: 500).navigationTitle("新增投资记录") }
}

struct TransactionEditSheet: View {
    let record: LedgerRecord; let accounts: [BrokerageAccount]; let onSave: (BrokerageAccount, Date, Decimal, Decimal, Decimal, String) -> Void
    @Environment(\.dismiss) private var dismiss; @State private var accountID: UUID; @State private var date: Date; @State private var first: Decimal; @State private var second: Decimal; @State private var fee: Decimal; @State private var note: String
    init(record: LedgerRecord, accounts: [BrokerageAccount], onSave: @escaping (BrokerageAccount, Date, Decimal, Decimal, Decimal, String) -> Void) { self.record = record; self.accounts = accounts; self.onSave = onSave; _accountID = State(initialValue: record.accountID ?? accounts.first!.id); _date = State(initialValue: record.date); _first = State(initialValue: record.quantity ?? record.amount); _second = State(initialValue: record.price ?? 0); _fee = State(initialValue: record.type == "股息" ? record.amount : 0); _note = State(initialValue: record.note) }
    var body: some View { Form { Picker("账户", selection: $accountID) { ForEach(accounts) { Text($0.name).tag($0.id) } }; DatePicker("日期", selection: $date); TextField(record.type == "股息" ? "税前股息" : "数量", value: $first, format: .number); TextField(record.type == "股息" ? "预扣税" : "价格", value: $second, format: .number); TextField(record.type == "股息" ? "实际到账" : "手续费", value: $fee, format: .number); TextField("备注", text: $note); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { guard let account = accounts.first(where: { $0.id == accountID }) else { return }; onSave(account, date, first, second, fee, note) }.buttonStyle(.borderedProminent).disabled(first < 0 || second < 0 || fee < 0) } }.formStyle(.grouped).padding().frame(width: 460) }
}

struct AccountEditSheet: View {
    let account: BrokerageAccount; let onSave: (String, String, String, Bool) -> Void; @Environment(\.dismiss) private var dismiss; @State private var name: String; @State private var broker: String; @State private var note: String; @State private var archived: Bool
    init(account: BrokerageAccount, onSave: @escaping (String, String, String, Bool) -> Void) { self.account = account; self.onSave = onSave; _name = State(initialValue: account.name); _broker = State(initialValue: account.broker); _note = State(initialValue: account.note); _archived = State(initialValue: account.isArchived) }
    var body: some View { Form { TextField("账户名称", text: $name); TextField("券商", text: $broker); TextField("备注", text: $note); Toggle("归档账户", isOn: $archived); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { onSave(name, broker, note, archived) }.disabled(name.isEmpty) } }.padding().frame(width: 450) }
}

struct InvestmentEditSheet: View {
    let investment: Investment; let onSave: (String, String, Decimal?, Bool) -> Void; @Environment(\.dismiss) private var dismiss; @State private var name: String; @State private var exchange: String; @State private var manual: Decimal?; @State private var watched: Bool
    init(investment: Investment, onSave: @escaping (String, String, Decimal?, Bool) -> Void) { self.investment = investment; self.onSave = onSave; _name = State(initialValue: investment.name); _exchange = State(initialValue: investment.exchange); _manual = State(initialValue: investment.manualPrice); _watched = State(initialValue: investment.isWatched) }
    var body: some View { Form { LabeledContent("代码", value: investment.symbol); TextField("名称", text: $name); TextField("交易所", text: $exchange); TextField("手工价格（美元）", value: $manual, format: .number); Toggle("自动刷新行情", isOn: $watched); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { onSave(name, exchange, manual, watched) }.disabled(name.isEmpty) } }.padding().frame(width: 450) }
}

struct PlanEditSheet: View {
    let plan: InvestmentPlan; let onSave: (String, Decimal) -> Void; @Environment(\.dismiss) private var dismiss; @State private var name: String; @State private var amount: Decimal
    init(plan: InvestmentPlan, onSave: @escaping (String, Decimal) -> Void) { self.plan = plan; self.onSave = onSave; _name = State(initialValue: plan.name); _amount = State(initialValue: plan.periodAmount) }
    var body: some View { Form { TextField("计划名称", text: $name); TextField("每期金额（美元）", value: $amount, format: .number); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { onSave(name, amount) }.disabled(name.isEmpty || amount <= 0) } }.padding().frame(width: 450) }
}

struct SettingsView: View {
    @State private var key = ""; @State private var status = "API Key 仅保存在系统钥匙串。"; private let store = KeychainAPIKeyStore()
    var body: some View { Form { Section("Twelve Data") { SecureField("API Key", text: $key); HStack { Button("保存") { do { try store.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; status = "API Key 已保存，请到投资标的页面刷新" } catch { status = "保存失败：\(error.localizedDescription)" } }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Button("删除", role: .destructive) { try? store.delete(); status = "API Key 已删除" } }; Text(status).foregroundStyle(.secondary) }; Section("行情说明") { Text("应用启动和手动操作时刷新关注标的。失败会保留最后成功价格，并显示具体错误。") } }.formStyle(.grouped).navigationTitle("设置") }
}

private extension Result { var isSuccess: Bool { if case .success = self { true } else { false } } }
