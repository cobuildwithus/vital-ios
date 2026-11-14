import XCTest
import Foundation
import HealthKit

@testable import VitalHealthKit
@testable import VitalCore

class ActivityLookbackTests: XCTestCase {

  private let calendar = GregorianCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
  private let historyStart = GregorianCalendar.FloatingDate(year: 2026, month: 1, day: 1)
  private let lastUploadedDay = GregorianCalendar.FloatingDate(year: 2026, month: 6, day: 10)

  /// The day summary anchor stores the day after the last day uploaded.
  private var lastSynced: GregorianCalendar.FloatingDate {
    calendar.offset(lastUploadedDay, byDays: 1)
  }

  private func lowerBound(daysSinceLastUpload gap: Int) -> GregorianCalendar.FloatingDate {
    let today = calendar.offset(lastUploadedDay, byDays: gap)

    return activityDailyStageLowerBound(
      // `handleActivity` caps the stored anchor at today.
      lastSynced: min(lastSynced, today),
      proposedLowerBound: historyStart,
      proposedUpperBound: today,
      in: calendar
    )
  }

  /// The last day uploaded was still in progress at the time, so the next sync must
  /// recompute it however long the gap. It used to be left out once the gap exceeded
  /// the lookback, which froze that day at its partial total.
  func testLastUploadedDayIsRecomputedAfterAnyGap() {
    for gap in 0 ... 30 {
      XCTAssertLessThanOrEqual(lowerBound(daysSinceLastUpload: gap), lastUploadedDay, "gap of \(gap) days")
    }

    XCTAssertEqual(lowerBound(daysSinceLastUpload: 8), lastUploadedDay)
    XCTAssertEqual(lowerBound(daysSinceLastUpload: 30), lastUploadedDay)
  }

  func testLookbackWindowIsRecomputedWithoutAGap() {
    XCTAssertEqual(activityStatsDaysToLookback, 7)

    let today = lastUploadedDay
    XCTAssertEqual(
      lowerBound(daysSinceLastUpload: 0),
      calendar.offset(today, byDays: -activityStatsDaysToLookback)
    )
  }

  func testLowerBoundNeverPrecedesTheHistoricalStart() {
    let today = calendar.offset(historyStart, byDays: 2)

    XCTAssertEqual(
      activityDailyStageLowerBound(
        lastSynced: today,
        proposedLowerBound: historyStart,
        proposedUpperBound: today,
        in: calendar
      ),
      historyStart
    )

    // No anchor stored yet.
    XCTAssertEqual(
      activityDailyStageLowerBound(
        lastSynced: GregorianCalendar.utc.floatingDate(of: .distantPast),
        proposedLowerBound: historyStart,
        proposedUpperBound: today,
        in: calendar
      ),
      historyStart
    )
  }

  /// `handleActivity` asks HealthKit for the range the lower bound says it should.
  func testHandleActivityQueriesFromTheLastUploadedDay() async throws {
    let calendar = GregorianCalendar(timeZone: .current)
    let now = Date()
    let lastUploadedDay = calendar.offset(calendar.floatingDate(of: now), byDays: -10)

    let storage = VitalHealthKitStorage(storage: .debug)
    storage.store(
      entity: StoredAnchor(
        key: "activityDaySummary",
        anchor: nil,
        date: GregorianCalendar.utc.startOfDay(calendar.offset(lastUploadedDay, byDays: 1)),
        vitalAnchors: nil
      )
    )

    let queried = QueriedIntervals()
    var dependencies = StatisticsQueryDependencies.debug
    dependencies.executeStatisticalQuery = { _, interval, _, _ in
      queried.append(interval)
      return []
    }

    _ = try await handleActivity(
      healthKitStore: HKHealthStore(),
      vitalStorage: storage,
      instruction: SyncInstruction(stage: .daily, query: Date.dateAgo(now, days: 30) ..< now),
      options: ReadOptions(),
      dependencies: dependencies
    )

    XCTAssertFalse(queried.values.isEmpty)
    XCTAssertEqual(queried.values.map(\.lowerBound).min(), calendar.startOfDay(lastUploadedDay))
  }

  /// `queryHourlyStatistics` asks HealthKit for the range the earliest hour says it should.
  func testQueryHourlyStatisticsQueriesFromTheLastUploadedHour() async throws {
    let now = Date()
    let lastUploadedHour = now.addingTimeInterval(-10 * 86400).beginningHour

    let storage = VitalHealthKitStorage(storage: .debug)
    storage.store(
      entity: StoredAnchor(
        key: "hourly-\(HKQuantityTypeIdentifier.stepCount.rawValue)",
        anchor: nil,
        date: lastUploadedHour.addingTimeInterval(3600),
        vitalAnchors: nil
      )
    )

    let queried = QueriedIntervals()
    var dependencies = StatisticsQueryDependencies.debug
    dependencies.executeStatisticalQuery = { _, interval, _, _ in
      queried.append(interval)
      return []
    }

    _ = try await queryHourlyStatistics(
      HKHealthStore(),
      storage,
      .stepCount,
      SyncInstruction(stage: .daily, query: Date.dateAgo(now, days: 30) ..< now),
      dependencies: dependencies
    )

    XCTAssertEqual(queried.values, [lastUploadedHour ..< now.nextHour])
  }

  /// The hourly anchor stores the end of the last hour uploaded. That hour was still in
  /// progress, so it is recomputed however long the gap.
  func testLastUploadedHourIsRecomputedAfterAnyGap() {
    let historyStart = Date(timeIntervalSince1970: 1_750_000_000).dayStart
    let lastUploadedHour = historyStart.addingTimeInterval(100 * 86400 + 9 * 3600)
    let lastSynced = lastUploadedHour.addingTimeInterval(3600)

    for gapInDays in [0, 1, 7, 8, 30] {
      let now = lastUploadedHour.addingTimeInterval(TimeInterval(gapInDays) * 86400 + 1800)
      let earliest = hourlyStatisticsDailyStageEarliest(lastSynced: lastSynced, query: historyStart ..< now)

      XCTAssertLessThanOrEqual(earliest, lastUploadedHour, "gap of \(gapInDays) days")
      XCTAssertGreaterThanOrEqual(earliest, historyStart)
    }

    let now = lastUploadedHour.addingTimeInterval(30 * 86400 + 1800)
    XCTAssertEqual(
      hourlyStatisticsDailyStageEarliest(lastSynced: lastSynced, query: historyStart ..< now),
      lastUploadedHour
    )

    // No anchor stored yet.
    XCTAssertEqual(
      hourlyStatisticsDailyStageEarliest(lastSynced: .distantPast, query: historyStart ..< now),
      historyStart
    )
  }
}

private final class QueriedIntervals: @unchecked Sendable {
  private let lock = NSLock()
  private var intervals: [Range<Date>] = []

  func append(_ interval: Range<Date>) {
    lock.withLock { intervals.append(interval) }
  }

  var values: [Range<Date>] {
    lock.withLock { intervals }
  }
}
