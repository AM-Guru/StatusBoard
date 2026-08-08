import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Health metrics from HealthKit — steps, energy, exercise, heart rate,
/// sleep. Available on iPhone/iPad/Watch; other platforms see the values
/// through iCloud sync or the bridge.
public enum HealthSource {
    #if canImport(HealthKit)
    private static let store = HKHealthStore()

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else {
            return .error("Health data isn't available on this device")
        }
        let metric = settings.healthMetric
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            let value: Double?
            switch metric {
            case .steps:
                value = try await todaySum(.stepCount, unit: .count())
            case .activeEnergy:
                value = try await todaySum(.activeEnergyBurned, unit: .kilocalorie())
            case .exerciseMinutes:
                value = try await todaySum(.appleExerciseTime, unit: .minute())
            case .heartRate:
                value = try await latestQuantity(.heartRate,
                                                 unit: HKUnit.count().unitDivided(by: .minute()))
            case .sleepHours:
                value = try await sleepHoursLastNight()
            }
            guard let value else {
                return .error("No \(metric.displayName.lowercased()) recorded yet")
            }
            return .number((value * 10).rounded() / 10, unit: settings.unit ?? metric.unit)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount),
         HKQuantityType(.activeEnergyBurned),
         HKQuantityType(.appleExerciseTime),
         HKQuantityType(.heartRate),
         HKCategoryType(.sleepAnalysis)]
    }

    private static func todaySum(_ identifier: HKQuantityTypeIdentifier,
                                 unit: HKUnit) async throws -> Double? {
        let type = HKQuantityType(identifier)
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type,
                                          quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
                }
            }
            store.execute(query)
        }
    }

    private static func latestQuantity(_ identifier: HKQuantityTypeIdentifier,
                                       unit: HKUnit) async throws -> Double? {
        let type = HKQuantityType(identifier)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let sample = samples?.first as? HKQuantitySample
                    continuation.resume(returning: sample?.quantity.doubleValue(for: unit))
                }
            }
            store.execute(query)
        }
    }

    private static func sleepHoursLastNight() async throws -> Double? {
        let type = HKCategoryType(.sleepAnalysis)
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]
                let seconds = (samples as? [HKCategorySample] ?? [])
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                continuation.resume(returning: seconds > 0 ? seconds / 3600 : nil)
            }
            store.execute(query)
        }
    }
    #else
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        if settings.syncSnapshotToICloud == true {
            return .error("Waiting for this Health panel's opted-in value from private iCloud")
        }
        return .error("Health is unavailable here. Enable private-iCloud value sync for this panel on a device that can read Health.")
    }
    #endif
}
