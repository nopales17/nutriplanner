# NutriPlanner

NutriPlanner is an iOS app that turns plain-language meal descriptions into estimated nutrition data and writes the result directly to Apple Health.

Built as a focused product-style project to demonstrate practical SwiftUI/UIKit integration, async networking, and HealthKit data workflows.

## What It Does

- Estimates nutrition from text using the OpenAI Responses API
- Logs macros + micronutrients to Apple Health
- Keeps a local meal log with editable entries
- Supports queue-based logging so multiple meals can be entered quickly
- Shows daily totals and a weekly summary visualization
- Includes a basic daily calorie goal calculator in Settings

## Why This Project Is Interesting

This app is intentionally small in scope but touches several real-world concerns:

- API integration with strict JSON extraction/decoding
- HealthKit permissions, writes, and targeted deletes
- Bridging SwiftUI and UIKit for advanced scrolling/sticky header behavior
- State-heavy UI flows (queueing, editing, async status, sectioned logs)
- User-facing product polish (cards, grouped logs, nutrition breakdowns)

## Tech Stack

- Swift 5
- SwiftUI (primary UI)
- UIKit (`UITableView` controller for high-control log interactions)
- HealthKit
- OpenAI Responses API

## Project Structure

- `nutriplanner/ContentView.swift` – Main app views (Estimate, Log, Settings)
- `nutriplanner/LogsTableView.swift` – SwiftUI wrapper for log table controller
- `nutriplanner/LogsTableViewController.swift` – UIKit diffable table + sticky section headers
- `nutriplanner/OpenAIClient.swift` – OpenAI request/response handling and JSON extraction
- `nutriplanner/HealthKitManager.swift` – HealthKit auth, write, and delete behavior
- `nutriplanner/NutritionEstimate.swift` – Nutrition model + aggregation helpers

## Run Locally

### Requirements

- Xcode 17+
- iOS Simulator or physical iPhone
- Apple Developer-capable environment for HealthKit usage
- OpenAI API key

### Steps

1. Open `nutriplanner.xcodeproj` in Xcode.
2. Select the `nutriplanner` scheme.
3. Build and run on a simulator/device.
4. In the app, go to **Settings** and paste your OpenAI API key.
5. Grant Health permissions when prompted.

## Notes

- API key is stored via app storage on-device for this project.
- Nutrition values are model estimates and may not match label-accurate nutrition data.
- This is a portfolio/demo app and not medical advice software.

## Future Improvements

- Per-day dynamic calorie goals
- Better meal history search/filtering
- Unit/integration tests for API parsing and log aggregation
- Optional cloud sync/auth layer
