//
//  NutritionEstimate.swift
//  nutriplanner
//
//  Created by Paolo on 1/28/26.
//

import Foundation

struct NutritionEstimate: Codable, Equatable {
    var dietary_energy_kcal: Double = 0

    var protein_g: Double = 0
    var carbs_g: Double = 0
    var fiber_g: Double = 0
    var sugar_g: Double = 0

    var fat_total_g: Double = 0
    var fat_saturated_g: Double = 0
    var fat_monounsaturated_g: Double = 0
    var fat_polyunsaturated_g: Double = 0

    var cholesterol_mg: Double = 0
    var sodium_mg: Double = 0
    var potassium_mg: Double = 0

    var vitamin_a_ug: Double = 0
    var vitamin_c_mg: Double = 0
    var vitamin_d_ug: Double = 0
    var vitamin_e_mg: Double = 0
    var vitamin_k_ug: Double = 0

    var vitamin_b6_mg: Double = 0
    var vitamin_b12_ug: Double = 0
    var thiamin_b1_mg: Double = 0
    var riboflavin_b2_mg: Double = 0
    var niacin_b3_mg: Double = 0
    var folate_ug: Double = 0
    var biotin_ug: Double = 0
    var pantothenic_acid_b5_mg: Double = 0

    var calcium_mg: Double = 0
    var iron_mg: Double = 0
    var phosphorus_mg: Double = 0
    var iodine_ug: Double = 0
    var magnesium_mg: Double = 0
    var zinc_mg: Double = 0
    var selenium_ug: Double = 0
    var copper_mg: Double = 0
    var manganese_mg: Double = 0
    var chromium_ug: Double = 0
    var molybdenum_ug: Double = 0
    var chloride_mg: Double = 0

    var caffeine_mg: Double = 0
    var water_mL: Double = 0
    var alcoholic_beverages_count: Double = 0
}

extension NutritionEstimate {
    static func + (lhs: NutritionEstimate, rhs: NutritionEstimate) -> NutritionEstimate {
        var total = NutritionEstimate()
        total.dietary_energy_kcal = lhs.dietary_energy_kcal + rhs.dietary_energy_kcal
        total.protein_g = lhs.protein_g + rhs.protein_g
        total.carbs_g = lhs.carbs_g + rhs.carbs_g
        total.fiber_g = lhs.fiber_g + rhs.fiber_g
        total.sugar_g = lhs.sugar_g + rhs.sugar_g
        total.fat_total_g = lhs.fat_total_g + rhs.fat_total_g
        total.fat_saturated_g = lhs.fat_saturated_g + rhs.fat_saturated_g
        total.fat_monounsaturated_g = lhs.fat_monounsaturated_g + rhs.fat_monounsaturated_g
        total.fat_polyunsaturated_g = lhs.fat_polyunsaturated_g + rhs.fat_polyunsaturated_g
        total.cholesterol_mg = lhs.cholesterol_mg + rhs.cholesterol_mg
        total.sodium_mg = lhs.sodium_mg + rhs.sodium_mg
        total.potassium_mg = lhs.potassium_mg + rhs.potassium_mg
        total.vitamin_a_ug = lhs.vitamin_a_ug + rhs.vitamin_a_ug
        total.vitamin_c_mg = lhs.vitamin_c_mg + rhs.vitamin_c_mg
        total.vitamin_d_ug = lhs.vitamin_d_ug + rhs.vitamin_d_ug
        total.vitamin_e_mg = lhs.vitamin_e_mg + rhs.vitamin_e_mg
        total.vitamin_k_ug = lhs.vitamin_k_ug + rhs.vitamin_k_ug
        total.vitamin_b6_mg = lhs.vitamin_b6_mg + rhs.vitamin_b6_mg
        total.vitamin_b12_ug = lhs.vitamin_b12_ug + rhs.vitamin_b12_ug
        total.thiamin_b1_mg = lhs.thiamin_b1_mg + rhs.thiamin_b1_mg
        total.riboflavin_b2_mg = lhs.riboflavin_b2_mg + rhs.riboflavin_b2_mg
        total.niacin_b3_mg = lhs.niacin_b3_mg + rhs.niacin_b3_mg
        total.folate_ug = lhs.folate_ug + rhs.folate_ug
        total.biotin_ug = lhs.biotin_ug + rhs.biotin_ug
        total.pantothenic_acid_b5_mg = lhs.pantothenic_acid_b5_mg + rhs.pantothenic_acid_b5_mg
        total.calcium_mg = lhs.calcium_mg + rhs.calcium_mg
        total.iron_mg = lhs.iron_mg + rhs.iron_mg
        total.phosphorus_mg = lhs.phosphorus_mg + rhs.phosphorus_mg
        total.iodine_ug = lhs.iodine_ug + rhs.iodine_ug
        total.magnesium_mg = lhs.magnesium_mg + rhs.magnesium_mg
        total.zinc_mg = lhs.zinc_mg + rhs.zinc_mg
        total.selenium_ug = lhs.selenium_ug + rhs.selenium_ug
        total.copper_mg = lhs.copper_mg + rhs.copper_mg
        total.manganese_mg = lhs.manganese_mg + rhs.manganese_mg
        total.chromium_ug = lhs.chromium_ug + rhs.chromium_ug
        total.molybdenum_ug = lhs.molybdenum_ug + rhs.molybdenum_ug
        total.chloride_mg = lhs.chloride_mg + rhs.chloride_mg
        total.caffeine_mg = lhs.caffeine_mg + rhs.caffeine_mg
        total.water_mL = lhs.water_mL + rhs.water_mL
        total.alcoholic_beverages_count = lhs.alcoholic_beverages_count + rhs.alcoholic_beverages_count
        return total
    }
}
