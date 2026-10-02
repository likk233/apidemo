import Foundation

private var failures = 0

func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !condition() { recordFailure("assertion failed", file: file, line: line) } }
    catch { recordFailure(error.localizedDescription, file: file, line: line) }
}
func expectThrows(_ block: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try block(); recordFailure("expected an error", file: file, line: line) } catch {}
}
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "UsageCoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Required value missing"]) }
    return value
}

@main
enum Checks {
    static func main() async {
        let p = ParserTests()
        let h = HistoryTests()
        let v = ProviderTests()
        let tests: [(String, () async throws -> Void)] = [
            ("live windows, features and budget", { try p.testLiveWindowsAdditionalLimitsAndBudget() }),
            ("relative reset event timestamp", { try p.testLegacyRelativeResetAnchoredToEventNotRefresh() }),
            ("camelCase and credit-only", { try p.testCamelCaseAndCreditOnlyResponses() }),
            ("missing, invalid and boolean usage", { p.testMissingMalformedAndBooleanPercentAreNotZeroUsage() }),
            ("currencies and decimal precision", { try p.testDeepSeekCurrenciesAndDecimalPrecision() }),
            ("CNY selection without USD fallback", { try p.testCNYSelectionDoesNotFallBackToUSD() }),
            ("legacy settings retain CNY thresholds", { try p.testLegacyPreferencesKeepCNYThresholds() }),
            ("invalid amounts and duplicates", { p.testDeepSeekRejectsPartialNumbersAndDuplicateCurrency() }),
            ("JWT and API-key-only auth", { try p.testAuthJWTAccountFallbackAndAPIKeyOnlyLogin() }),
            ("consumption excluding top-ups", { try h.testSpendExcludesTopUpsAndKeepsCurrenciesSeparate() }),
            ("minimum estimation span", { h.testEstimateNeedsThirtyMinutesAndConsumption() }),
            ("bounded history", { h.testHistoryBoundedAndDuplicateRefreshNotRecorded() }),
            ("threshold validation", { h.testThresholdValidation() }),
            ("warnings deduplicate, persist and rearm", { try h.testWarningsDeduplicateRearmAndPersistAcrossLaunch() }),
            ("API headers and read-only auth", { try await v.testAPIUsesExistingCredentialWithoutModifyingFile() }),
            ("401 fallback and offline no network", { try await v.testUnauthorizedFallsBackAndOfflineNeverCallsNetwork() }),
            ("reverse scan and cache invalidation", { try await v.testReverseScanHandlesChunkBoundariesPartialLinesAndCacheInvalidation() }),
            ("event time vs touched file", { try await v.testUsesEventTimestampRatherThanTouchedFileOrder() }),
            ("oversized conversation line", { try await v.testVeryLongConversationLineDoesNotHideEarlierEvent() }),
            ("HTTP error categories", { try await v.testDeepSeekTypedFailures() })
        ]
        for (name, run) in tests {
            let before = failures
            do { try await run() } catch { recordFailure("\(name): \(error.localizedDescription)") }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(tests.count) regression checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
