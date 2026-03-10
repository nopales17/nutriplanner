//
//  OpenAIClient.swift
//  nutriplanner
//
//  Created by Paolo on 1/28/26.
//

import Foundation

enum OpenAIError: Error, LocalizedError {
    case badURL
    case timeout
    case badResponse(statusCode: Int, message: String?)
    case missingJSON

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid OpenAI endpoint."
        case .timeout:
            return "OpenAI request timed out. Please try again."
        case let .badResponse(statusCode, message):
            if let message, !message.isEmpty {
                return "OpenAI error (\(statusCode)): \(message)"
            }
            return "OpenAI returned an error (\(statusCode))."
        case .missingJSON:
            return "OpenAI returned an unexpected response format."
        }
    }
}

final class OpenAIClient {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    static var lastExtractedJSON: String?

    init(apiKey: String, model: String = "gpt-5-nano") {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func estimateNutrition(mealText: String) async throws -> NutritionEstimate {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else { throw OpenAIError.badURL }

        let prompt = """
        You are a nutrition estimator for Apple Health logging.
        Meal: "\(mealText)"

        Return ONLY valid JSON. All values must be numbers.
        Always estimate all macros and micros, even if the user only provides calories or partial info.
        If only calories are given, infer a reasonable macro split and fill out the remaining fields.
        Do not leave macros at 0 unless the meal truly has 0 of that nutrient.
        Use these units:
        - kcal: dietary_energy_kcal
        - g: macros/fats/fiber/sugar
        - mg: cholesterol, sodium, potassium, caffeine, calcium, iron, magnesium, zinc, copper, manganese, phosphorus, chloride, vitamin C/E, B1/B2/B3/B5/B6
        - µg: vitamin A, D, K, B12, folate, biotin, iodine, selenium, chromium, molybdenum
        - mL: water
        - count: alcoholic_beverages_count

        JSON keys:
        {
        "dietary_energy_kcal":0,
        "protein_g":0,"carbs_g":0,"fiber_g":0,"sugar_g":0,
        "fat_total_g":0,"fat_saturated_g":0,"fat_monounsaturated_g":0,"fat_polyunsaturated_g":0,
        "cholesterol_mg":0,"sodium_mg":0,"potassium_mg":0,

        "vitamin_a_ug":0,"vitamin_c_mg":0,"vitamin_d_ug":0,"vitamin_e_mg":0,"vitamin_k_ug":0,
        "vitamin_b6_mg":0,"vitamin_b12_ug":0,"thiamin_b1_mg":0,"riboflavin_b2_mg":0,"niacin_b3_mg":0,
        "folate_ug":0,"biotin_ug":0,"pantothenic_acid_b5_mg":0,

        "calcium_mg":0,"iron_mg":0,"phosphorus_mg":0,"iodine_ug":0,"magnesium_mg":0,"zinc_mg":0,
        "selenium_ug":0,"copper_mg":0,"manganese_mg":0,"chromium_ug":0,"molybdenum_ug":0,"chloride_mg":0,

        "caffeine_mg":0,"water_mL":0,
        "alcoholic_beverages_count":0
        }
        """

        let body: [String: Any] = [
            "model": model,
            "input": prompt
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw OpenAIError.timeout
        }
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let responseSize = data.count
        let raw = String(data: data, encoding: .utf8) ?? ""
        let rawPreview = String(raw.prefix(500)).replacingOccurrences(of: apiKey, with: "<redacted>")
        print("[OpenAI] status=\(statusCode) bytes=\(responseSize)")
        print("[OpenAI] response preview=\n\(rawPreview)")
        guard (200...299).contains(statusCode) else {
            throw OpenAIError.badResponse(statusCode: statusCode, message: Self.extractAPIErrorMessage(from: data))
        }

        // Responses API returns a big JSON. Prefer the output text field if available.
        let candidateText = Self.extractOutputText(from: data) ?? raw
        guard let jsonText = Self.firstJSONObjectString(in: candidateText) else { throw OpenAIError.missingJSON }
        Self.lastExtractedJSON = jsonText
        print("[OpenAI] extracted JSON=\n\(String(jsonText.prefix(500)))")

        do {
            let decoded = try JSONDecoder().decode(NutritionEstimate.self, from: Data(jsonText.utf8))
            return decoded
        } catch {
            print("[OpenAI] decode error=\(error)")
            throw error
        }
    }

    // Finds the first {...} block in a string (good enough for strict “JSON only” prompting).
    private static func firstJSONObjectString(in text: String) -> String? {
        let needle = "{\"dietary_energy_kcal\""
        let start = text.range(of: needle)?.lowerBound ?? text.firstIndex(of: "{")
        guard let start else { return nil }
        var depth = 0
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            if depth == 0 && ch == "}" {
                return String(text[start...i])
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func extractOutputText(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let dict = json as? [String: Any],
            let output = dict["output"] as? [[String: Any]]
        else { return nil }

        for item in output {
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if let text = part["text"] as? String {
                        return text
                    }
                }
            }
        }
        return nil
    }

    private static func extractAPIErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let dict = json as? [String: Any],
            let error = dict["error"] as? [String: Any]
        else { return nil }

        return error["message"] as? String
    }
}
