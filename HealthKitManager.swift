//
//  HealthKitManager.swift
//  nutriplanner
//
//  Created by Paolo on 1/28/26.
//

import Foundation
import HealthKit

final class HealthKitManager {
    private let store = HKHealthStore()

    func requestAuth() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        // All the nutrition types you want to WRITE.
        let typesToShare: Set<HKSampleType> = Set(Self.mapping.values.compactMap { HKObjectType.quantityType(forIdentifier: $0) })

        print("[HealthKit] requestAuth typesToShare=\(typesToShare.count)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: typesToShare, read: []) { success, error in
                print("[HealthKit] requestAuth success=\(success) error=\(String(describing: error))")
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: ())
            }
        }
    }

    func writeAll(_ n: NutritionEstimate, date: Date = Date(), entryID: UUID) async throws {
        var samples: [HKQuantitySample] = []

        let entryIDString = entryID.uuidString
        let metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: entryIDString,
            "nutriplanner_entry_id": entryIDString
        ]

        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double) {
            guard value != 0, let type = HKObjectType.quantityType(forIdentifier: id) else { return }
            let qty = HKQuantity(unit: unit, doubleValue: value)
            samples.append(HKQuantitySample(type: type, quantity: qty, start: date, end: date, metadata: metadata))
        }

        // Energy/macros
        add(.dietaryEnergyConsumed, .kilocalorie(), n.dietary_energy_kcal)
        add(.dietaryProtein, .gram(), n.protein_g)
        add(.dietaryCarbohydrates, .gram(), n.carbs_g)
        add(.dietaryFiber, .gram(), n.fiber_g)
        add(.dietarySugar, .gram(), n.sugar_g)

        // Fats
        add(.dietaryFatTotal, .gram(), n.fat_total_g)
        add(.dietaryFatSaturated, .gram(), n.fat_saturated_g)
        add(.dietaryFatMonounsaturated, .gram(), n.fat_monounsaturated_g)
        add(.dietaryFatPolyunsaturated, .gram(), n.fat_polyunsaturated_g)

        // Other
        add(.dietaryCholesterol, .gramUnit(with: .milli), n.cholesterol_mg)
        add(.dietarySodium, .gramUnit(with: .milli), n.sodium_mg)
        add(.dietaryPotassium, .gramUnit(with: .milli), n.potassium_mg)

        // Vitamins
        add(.dietaryVitaminA, .gramUnit(with: .micro), n.vitamin_a_ug)
        add(.dietaryVitaminC, .gramUnit(with: .milli), n.vitamin_c_mg)
        add(.dietaryVitaminD, .gramUnit(with: .micro), n.vitamin_d_ug)
        add(.dietaryVitaminE, .gramUnit(with: .milli), n.vitamin_e_mg)
        add(.dietaryVitaminK, .gramUnit(with: .micro), n.vitamin_k_ug)

        add(.dietaryVitaminB6, .gramUnit(with: .milli), n.vitamin_b6_mg)
        add(.dietaryVitaminB12, .gramUnit(with: .micro), n.vitamin_b12_ug)
        add(.dietaryThiamin, .gramUnit(with: .milli), n.thiamin_b1_mg)
        add(.dietaryRiboflavin, .gramUnit(with: .milli), n.riboflavin_b2_mg)
        add(.dietaryNiacin, .gramUnit(with: .milli), n.niacin_b3_mg)
        add(.dietaryFolate, .gramUnit(with: .micro), n.folate_ug)
        add(.dietaryBiotin, .gramUnit(with: .micro), n.biotin_ug)
        add(.dietaryPantothenicAcid, .gramUnit(with: .milli), n.pantothenic_acid_b5_mg)

        // Minerals
        add(.dietaryCalcium, .gramUnit(with: .milli), n.calcium_mg)
        add(.dietaryIron, .gramUnit(with: .milli), n.iron_mg)
        add(.dietaryPhosphorus, .gramUnit(with: .milli), n.phosphorus_mg)
        add(.dietaryIodine, .gramUnit(with: .micro), n.iodine_ug)
        add(.dietaryMagnesium, .gramUnit(with: .milli), n.magnesium_mg)
        add(.dietaryZinc, .gramUnit(with: .milli), n.zinc_mg)
        add(.dietarySelenium, .gramUnit(with: .micro), n.selenium_ug)
        add(.dietaryCopper, .gramUnit(with: .milli), n.copper_mg)
        add(.dietaryManganese, .gramUnit(with: .milli), n.manganese_mg)
        add(.dietaryChromium, .gramUnit(with: .micro), n.chromium_ug)
        add(.dietaryMolybdenum, .gramUnit(with: .micro), n.molybdenum_ug)
        add(.dietaryChloride, .gramUnit(with: .milli), n.chloride_mg)

        // Stimulant/hydration
        add(.dietaryCaffeine, .gramUnit(with: .milli), n.caffeine_mg)
        add(.dietaryWater, .literUnit(with: .milli), n.water_mL)

        // Alcohol “count”
        add(.numberOfAlcoholicBeverages, .count(), n.alcoholic_beverages_count)

        print("[HealthKit] save samples=\(samples.count)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.save(samples) { success, error in
                print("[HealthKit] save success=\(success) error=\(String(describing: error))")
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: ())
            }
        }
    }

    func deleteAll(for entryID: UUID) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let entryIDString = entryID.uuidString
        let externalPredicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: [entryIDString]
        )
        let customPredicate = HKQuery.predicateForObjects(
            withMetadataKey: "nutriplanner_entry_id",
            allowedValues: [entryIDString]
        )
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [externalPredicate, customPredicate])
        let typesToDelete: [HKObjectType] = Self.mapping.values.compactMap { HKObjectType.quantityType(forIdentifier: $0) }

        for type in typesToDelete {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                store.deleteObjects(of: type, predicate: predicate) { success, deletedCount, error in
                    print("[HealthKit] delete type=\(type.identifier) success=\(success) deleted=\(deletedCount) error=\(String(describing: error))")
                    if let error { cont.resume(throwing: error); return }
                    cont.resume(returning: ())
                }
            }
        }
    }

    // Helps build the auth set (Apple lists nutrition identifiers here).  [oai_citation:2‡Apple Developer](https://developer.apple.com/documentation/healthkit/nutrition-type-identifiers?utm_source=chatgpt.com)
    private static let mapping: [String: HKQuantityTypeIdentifier] = [
        // Energy/macros
        "dietary_energy_kcal": .dietaryEnergyConsumed,
        "protein_g": .dietaryProtein,
        "carbs_g": .dietaryCarbohydrates,
        "fiber_g": .dietaryFiber,
        "sugar_g": .dietarySugar,

        // Fats
        "fat_total_g": .dietaryFatTotal,
        "fat_saturated_g": .dietaryFatSaturated,
        "fat_monounsaturated_g": .dietaryFatMonounsaturated,
        "fat_polyunsaturated_g": .dietaryFatPolyunsaturated,

        // Other
        "cholesterol_mg": .dietaryCholesterol,
        "sodium_mg": .dietarySodium,
        "potassium_mg": .dietaryPotassium,

        // Vitamins
        "vitamin_a_ug": .dietaryVitaminA,
        "vitamin_c_mg": .dietaryVitaminC,
        "vitamin_d_ug": .dietaryVitaminD,
        "vitamin_e_mg": .dietaryVitaminE,
        "vitamin_k_ug": .dietaryVitaminK,
        "vitamin_b6_mg": .dietaryVitaminB6,
        "vitamin_b12_ug": .dietaryVitaminB12,
        "thiamin_b1_mg": .dietaryThiamin,
        "riboflavin_b2_mg": .dietaryRiboflavin,
        "niacin_b3_mg": .dietaryNiacin,
        "folate_ug": .dietaryFolate,
        "biotin_ug": .dietaryBiotin,
        "pantothenic_acid_b5_mg": .dietaryPantothenicAcid,

        // Minerals
        "calcium_mg": .dietaryCalcium,
        "iron_mg": .dietaryIron,
        "phosphorus_mg": .dietaryPhosphorus,
        "iodine_ug": .dietaryIodine,
        "magnesium_mg": .dietaryMagnesium,
        "zinc_mg": .dietaryZinc,
        "selenium_ug": .dietarySelenium,
        "copper_mg": .dietaryCopper,
        "manganese_mg": .dietaryManganese,
        "chromium_ug": .dietaryChromium,
        "molybdenum_ug": .dietaryMolybdenum,
        "chloride_mg": .dietaryChloride,

        // Stimulant/hydration
        "caffeine_mg": .dietaryCaffeine,
        "water_mL": .dietaryWater,

        // Alcohol “count”
        "alcoholic_beverages_count": .numberOfAlcoholicBeverages,
    ]
}
