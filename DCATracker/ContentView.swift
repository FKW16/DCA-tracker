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

struct DashboardView: View {
    @Query private var investments: [Investment]
    @Query private var purchases: [Purchase]
    @Query private var sales: [Sale]
    @State private var spyPrices: [HistoricalPrice] = []; @State private var spyStatus = "尚未加载 SPY 基准"
    private var snapshot: DashboardSnapshot { DashboardAnalytics.snapshot(investments: investments, purchases: purchases, sales: sales) }
    private var invested: Decimal { purchases.reduce(0) { $0 + $1.quantity * $1.price + $1.fee } }
    private var marketValue: Decimal { snapshot.marketValue }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("投资总览").font(.largeTitle.bold())
            HStack { MetricCard(title: "累计投入", value: invested); MetricCard(title: "当前市值", value: marketValue); MetricCard(title: "浮动差额", value: marketValue - invested) }
            if investments.isEmpty { ContentUnavailableView("还没有投资标的", systemImage: "chart.pie", description: Text("请先添加账户和标的，再到交易台账手动新增记录。")) } else {
                GroupBox("持仓市值结构") { VStack { Chart(snapshot.holdings) { item in SectorMark(angle: .value("市值", NSDecimalNumber(decimal: item.marketValue).doubleValue), innerRadius: .ratio(0.55)).foregroundStyle(by: .value("代码", item.symbol)) }.frame(height: 240); ForEach(snapshot.holdings) { item in HStack { Text(item.symbol); Spacer(); Text(USDFormat.string(item.marketValue)); Text(item.weight, format: .percent.precision(.fractionLength(1))) } }; if !snapshot.missingPriceSymbols.isEmpty { Label("缺少有效价格，已排除：\(snapshot.missingPriceSymbols.joined(separator: ", "))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } } }
                GroupBox("组合曲线") { VStack(alignment: .leading) { if let curve = benchmarkCurve, !curve.isEmpty { Chart(curve) { point in LineMark(x: .value("月份", point.date, unit: .month), y: .value("收益率", NSDecimalNumber(decimal: point.benchmarkReturn).doubleValue)).foregroundStyle(by: .value("曲线", "SPY")); if let portfolioReturn = point.portfolioReturn { LineMark(x: .value("月份", point.date, unit: .month), y: .value("收益率", NSDecimalNumber(decimal: portfolioReturn).doubleValue)).foregroundStyle(by: .value("曲线", "组合")) } }.chartXAxis { AxisMarks(values: .stride(by: .month)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.year().month(.abbreviated)) } }.chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1)) }.frame(height: 220) } else { ContentUnavailableView("基准暂不可计算", systemImage: "chart.line.uptrend.xyaxis", description: Text(spyStatus)) }; Text("组合仅显示首期与当前真实端点，不伪造缺失的资产历史行情。").font(.caption).foregroundStyle(.secondary); Text(spyStatus).font(.caption).foregroundStyle(.secondary) } }
                GroupBox("月度投入") { Chart(snapshot.monthlyContributions) { BarMark(x: .value("月份", $0.month, unit: .month), y: .value("投入", NSDecimalNumber(decimal: $0.amount).doubleValue)) }.chartXAxis { AxisMarks(values: .stride(by: .month)) { AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.year().month(.abbreviated)) } }.frame(height: 180) }
                GroupBox("券商账户持仓") {
                    if snapshot.accountHoldings.isEmpty {
                        ContentUnavailableView("暂无账户持仓", systemImage: "chart.pie", description: Text("录入买入记录并设置有效价格后显示。"))
                    } else {
                        VStack {
                            Chart(snapshot.accountHoldings) { item in
                                SectorMark(angle: .value("市值", NSDecimalNumber(decimal: item.marketValue).doubleValue), innerRadius: .ratio(0.55))
                                    .foregroundStyle(by: .value("账户", item.accountName))
                            }.frame(height: 240)
                            ForEach(snapshot.accountHoldings) { item in
                                HStack { Text(item.accountName); Spacer(); Text(USDFormat.string(item.marketValue)); Text(item.weight, format: .percent.precision(.fractionLength(1))) }
                            }
                        }
                    }
                }
            }
        }.padding(24) }.task { await refreshSPY() }
    }
    private var benchmarkCurve: [ReturnPoint]? { BenchmarkDashboard.curve(purchases: purchases, sales: sales, spyPrices: spyPrices, currentPortfolioValue: marketValue) }
    @MainActor private func refreshSPY() async { guard let key = try? KeychainAPIKeyStore().read(), !key.isEmpty, let cache = try? HistoricalQuoteCache() else { spyStatus = "保存 Twelve Data Key 后可加载 SPY；已有缓存仍可离线使用"; if let cache = try? HistoricalQuoteCache() { spyPrices = cache.load(symbol: "SPY") }; return }; let result = await HistoricalQuoteService(source: TwelveDataSource(), cache: cache).refresh(symbol: "SPY", apiKey: key); spyPrices = result.prices; spyStatus = result.error.map { "网络失败，使用缓存（\(spyPrices.last?.date.formatted(date: .abbreviated, time: .omitted) ?? "无缓存")）：\($0)" } ?? "SPY 更新：\(spyPrices.last?.date.formatted(date: .abbreviated, time: .omitted) ?? "无数据")" }
}

struct MetricCard: View {
    let title: String; let value: Decimal
    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Text(USDFormat.string(value))
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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
    @Environment(\.modelContext) private var context; @Query private var investments: [Investment]
    @State private var symbol = ""; @State private var manual: Decimal?; @State private var status = ""; @State private var editing: Investment?
    private let coordinator = QuoteCoordinator(source: TwelveDataSource())
    var body: some View { Form {
        Section("新增标的") { TextField("代码", text: $symbol); TextField("手工价格（美元，可选）", value: $manual, format: .number); Button("添加") { let item = Investment(symbol: symbol, name: symbol); item.manualPrice = manual; context.insert(item); try? context.save(); symbol = ""; manual = nil }.disabled(symbol.isEmpty); Button("刷新全部关注标的") { Task { await refresh() } }; Text(status).font(.caption).foregroundStyle(.secondary) }
        Section("行情（自动→缓存→手工）") { ForEach(investments) { item in HStack { VStack(alignment: .leading) { Text(item.symbol).font(.headline); Text(item.quoteUpdatedAt.map { "更新：\($0.formatted())" } ?? "尚无自动行情").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(USDFormat.string(item.latestPrice ?? item.manualPrice ?? 0)); Button("编辑") { editing = item } } } }
    }.formStyle(.grouped).navigationTitle("投资标的").task { await refresh() }.sheet(item: $editing) { item in InvestmentEditSheet(investment: item) { name, exchange, manual, watched in item.name = name; item.exchange = exchange; item.manualPrice = manual; item.isWatched = watched; try? context.save(); editing = nil } } }
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
    @State private var selectedType = "all"; @State private var selectedTagIDs: Set<UUID> = []; @State private var exporting = false; @State private var document = ExportDocument(); @State private var exportType = UTType.json; @State private var exportName = "DCA-Tracker"; @State private var message = ""; @State private var pendingDelete: LedgerRecord?; @State private var editing: LedgerRecord?; @State private var adding = false
    private var records: [LedgerRecord] {
        let buys = selectedType == "all" || selectedType == "buy" ? purchases.compactMap(buyRecord) : []
        let sells = selectedType == "all" || selectedType == "sell" ? sales.compactMap(saleRecord) : []
        let income = selectedType == "all" || selectedType == "dividend" ? dividends.compactMap(dividendRecord) : []
        return (buys + sells + income).sorted { $0.date > $1.date }
    }
    var body: some View { VStack {
        HStack { Button("新增投资记录", systemImage: "plus") { adding = true }.buttonStyle(.borderedProminent).disabled(accounts.isEmpty || investments.isEmpty); Picker("类型", selection: $selectedType) { Text("全部").tag("all"); Text("买入").tag("buy"); Text("卖出").tag("sell"); Text("股息").tag("dividend") }.frame(width: 180); Spacer(); Button("导出 CSV") { document = .init(data: ExportService.csv(records)); exportType = .commaSeparatedText; exportName = "DCA-Tracker-ledger"; exporting = true }; Button("导出完整 JSON") { exportBackup() } }.padding()
        if accounts.isEmpty || investments.isEmpty { ContentUnavailableView("先完成基础设置", systemImage: "tray", description: Text("请先添加至少一个券商账户和投资标的。")) } else if records.isEmpty { ContentUnavailableView("还没有投资记录", systemImage: "list.bullet.rectangle", description: Text("点击左上角“新增投资记录”手动录入买入、卖出或股息。")) } else { Table(records) { TableColumn("类型", value: \.type); TableColumn("日期") { Text($0.date, format: .dateTime.year().month().day()) }; TableColumn("标的", value: \.symbol); TableColumn("账户", value: \.account); TableColumn("金额") { Text(USDFormat.string($0.amount)) }; TableColumn("操作") { record in HStack { Button("编辑") { editing = record }; Button("删除", role: .destructive) { pendingDelete = record } } } } }
        if !message.isEmpty { Text(message).foregroundStyle(message.contains("失败") ? .red : .secondary).padding() }
    }.navigationTitle("交易台账")
      .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { message = $0.isSuccess ? "导出成功" : "导出失败" }
      .sheet(isPresented: $adding) { TransactionEntrySheet(accounts: accounts.filter { !$0.isArchived }, investments: investments) { draft in add(draft) } }
      .sheet(item: $editing) { record in TransactionEditSheet(record: record) { date, first, second, fee, note in applyEdit(record, date: date, first: first, second: second, fee: fee, note: note); editing = nil } }
      .confirmationDialog("确定删除这笔交易？", isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) { Button("删除", role: .destructive) { if let record = pendingDelete { delete(record) }; pendingDelete = nil }; Button("取消", role: .cancel) {} }
    }
    private func buyRecord(_ value: Purchase) -> LedgerRecord? { guard TransactionFilter.matches(tags: value.tags, selectedTagIDs: selectedTagIDs) else { return nil }; return .init(id: value.id, type: "买入", date: value.date, symbol: value.investment?.symbol ?? "", account: value.account?.name ?? "", quantity: value.quantity, price: value.price, amount: value.quantity * value.price + value.fee, tags: value.tags.map(\.name), note: value.note) }
    private func saleRecord(_ value: Sale) -> LedgerRecord? { guard TransactionFilter.matches(tags: value.tags, selectedTagIDs: selectedTagIDs) else { return nil }; return .init(id: value.id, type: "卖出", date: value.date, symbol: value.investment?.symbol ?? "", account: value.account?.name ?? "", quantity: value.quantity, price: value.price, amount: value.quantity * value.price - value.fee, tags: value.tags.map(\.name), note: value.note) }
    private func dividendRecord(_ value: Dividend) -> LedgerRecord? { guard TransactionFilter.matches(tags: value.tags, selectedTagIDs: selectedTagIDs) else { return nil }; return .init(id: value.id, type: "股息", date: value.date, symbol: value.investment?.symbol ?? "", account: value.account?.name ?? "", quantity: nil, price: nil, amount: value.receivedAmount, tags: value.tags.map(\.name), note: value.note) }
    private func add(_ draft: TransactionDraft) { guard draft.first > 0, draft.second >= 0, draft.fee >= 0 else { message = "保存失败：请输入有效数字"; return }; switch draft.kind { case .buy: context.insert(Purchase(date: draft.date, quantity: draft.first, price: draft.second, fee: draft.fee, note: draft.note, account: draft.account, investment: draft.investment)); case .sell: let held = purchases.filter { $0.account?.id == draft.account.id && $0.investment?.id == draft.investment.id }.reduce(0) { $0 + $1.quantity } - sales.filter { $0.account?.id == draft.account.id && $0.investment?.id == draft.investment.id }.reduce(0) { $0 + $1.quantity }; guard draft.first <= held else { message = "保存失败：可卖数量仅 \(held)"; return }; context.insert(Sale(date: draft.date, quantity: draft.first, price: draft.second, fee: draft.fee, note: draft.note, account: draft.account, investment: draft.investment)); case .dividend: guard draft.second <= draft.first else { message = "保存失败：预扣税不能超过税前股息"; return }; context.insert(Dividend(date: draft.date, grossAmount: draft.first, withholdingTax: draft.second, actualReceivedAmount: draft.fee, note: draft.note, account: draft.account, investment: draft.investment)) }; do { try context.save(); adding = false; message = "记录已保存" } catch { message = "保存失败：\(error.localizedDescription)" } }
    private func delete(_ record: LedgerRecord) { if let value = purchases.first(where: { $0.id == record.id }) { context.delete(value) }; if let value = sales.first(where: { $0.id == record.id }) { context.delete(value) }; if let value = dividends.first(where: { $0.id == record.id }) { context.delete(value) }; try? context.save() }
    private func applyEdit(_ record: LedgerRecord, date: Date, first: Decimal, second: Decimal, fee: Decimal, note: String) { guard first >= 0, second >= 0, fee >= 0 else { return }; if let value = purchases.first(where: { $0.id == record.id }) { value.date = date; value.quantity = first; value.price = second; value.fee = fee; value.note = note }; if let value = sales.first(where: { $0.id == record.id }) { value.date = date; value.quantity = first; value.price = second; value.fee = fee; value.note = note }; if let value = dividends.first(where: { $0.id == record.id }) { value.date = date; value.grossAmount = first; value.withholdingTax = second; value.actualReceivedAmount = fee; value.note = note }; try? context.save() }
    private var graph: BackupGraph { .init(accounts: accounts, investments: investments, tags: tags, purchases: purchases, sales: sales, dividends: dividends, portfolios: portfolios, assets: assets, plans: plans, executions: executions) }
    private func exportBackup() { if let data = try? FullBackupService.encode(FullBackupService.capture(graph)) { document = .init(data: data); exportType = .json; exportName = "DCA-Tracker-complete-backup"; exporting = true } }
}

enum TransactionDraftKind: String, CaseIterable, Identifiable { case buy = "买入", sell = "卖出", dividend = "股息"; var id: Self { self } }
struct TransactionDraft { let kind: TransactionDraftKind; let account: BrokerageAccount; let investment: Investment; let date: Date; let first, second, fee: Decimal; let note: String }

struct TransactionEntrySheet: View {
    let accounts: [BrokerageAccount]; let investments: [Investment]; let onSave: (TransactionDraft) -> Void
    @Environment(\.dismiss) private var dismiss; @State private var kind = TransactionDraftKind.buy; @State private var accountID: UUID; @State private var investmentID: UUID; @State private var date = Date(); @State private var first: Decimal = 0; @State private var second: Decimal = 0; @State private var fee: Decimal = 0; @State private var note = ""
    init(accounts: [BrokerageAccount], investments: [Investment], onSave: @escaping (TransactionDraft) -> Void) { self.accounts = accounts; self.investments = investments; self.onSave = onSave; _accountID = State(initialValue: accounts.first!.id); _investmentID = State(initialValue: investments.first!.id) }
    var body: some View { Form { Picker("类型", selection: $kind) { ForEach(TransactionDraftKind.allCases) { Text($0.rawValue).tag($0) } }; Picker("账户", selection: $accountID) { ForEach(accounts) { Text($0.name).tag($0.id) } }; Picker("标的", selection: $investmentID) { ForEach(investments) { Text($0.symbol).tag($0.id) } }; DatePicker("日期", selection: $date, displayedComponents: .date); TextField(kind == .dividend ? "税前股息" : "数量", value: $first, format: .number); TextField(kind == .dividend ? "预扣税" : "成交单价", value: $second, format: .number); TextField(kind == .dividend ? "实际到账" : "手续费", value: $fee, format: .number); TextField("备注", text: $note); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { guard let account = accounts.first(where: { $0.id == accountID }), let investment = investments.first(where: { $0.id == investmentID }) else { return }; onSave(.init(kind: kind, account: account, investment: investment, date: date, first: first, second: second, fee: fee, note: note)) }.buttonStyle(.borderedProminent).disabled(first <= 0 || second < 0 || fee < 0) } }.formStyle(.grouped).padding().frame(width: 500).navigationTitle("新增投资记录") }
}

struct TransactionEditSheet: View {
    let record: LedgerRecord; let onSave: (Date, Decimal, Decimal, Decimal, String) -> Void
    @Environment(\.dismiss) private var dismiss; @State private var date: Date; @State private var first: Decimal; @State private var second: Decimal; @State private var fee: Decimal; @State private var note: String
    init(record: LedgerRecord, onSave: @escaping (Date, Decimal, Decimal, Decimal, String) -> Void) { self.record = record; self.onSave = onSave; _date = State(initialValue: record.date); _first = State(initialValue: record.quantity ?? record.amount); _second = State(initialValue: record.price ?? 0); _fee = State(initialValue: record.type == "股息" ? record.amount : 0); _note = State(initialValue: record.note) }
    var body: some View { Form { DatePicker("日期", selection: $date); TextField(record.type == "股息" ? "税前股息" : "数量", value: $first, format: .number); TextField(record.type == "股息" ? "预扣税" : "价格", value: $second, format: .number); TextField(record.type == "股息" ? "实际到账" : "手续费", value: $fee, format: .number); TextField("备注", text: $note); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { onSave(date, first, second, fee, note) }.buttonStyle(.borderedProminent).disabled(first < 0 || second < 0 || fee < 0) } }.formStyle(.grouped).padding().frame(width: 460) }
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
