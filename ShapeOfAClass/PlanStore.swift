import Foundation
import Observation

@Observable
final class PlanStore {
    private(set) var plans: [Int: ClassPlan] = [:]
    private let url: URL

    init() {
        url = URL.documentsDirectory.appending(path: "plans.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Int: ClassPlan].self, from: data) {
            plans = decoded
        }
    }

    func plan(for week: Int) -> ClassPlan {
        plans[week] ?? ClassPlan(week: week)
    }

    func save(_ plan: ClassPlan) {
        var copy = plan
        copy.updated = .now
        plans[copy.week] = copy
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
