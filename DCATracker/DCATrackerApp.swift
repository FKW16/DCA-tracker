import SwiftData
import SwiftUI

@main
struct DCATrackerApp: App {
    private let container: ModelContainer = {
        let schema = Schema([
            BrokerageAccount.self, Investment.self, Purchase.self, Sale.self, Dividend.self,
            TransactionTag.self, InvestmentPortfolio.self, PortfolioAsset.self, InvestmentPlan.self, PlanExecution.self
        ])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Unable to create the application data store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
