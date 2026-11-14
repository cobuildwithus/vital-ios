import XCTest
import HealthKit
import Foundation

@testable import VitalHealthKit
@_spi(VitalSDKInternals) @testable import VitalCore

/// A sync that fails because the phone is locked must be retried by the next delivery
/// that gets through, even when that delivery is for a different resource.
class VitalHealthKitRetryTests: XCTestCase {

  private let delivered = RemappedVitalResource(wrapped: .vitals(.glucose))
  private let failedEarlier = RemappedVitalResource(wrapped: .nutrition(.water))

  private var activeResources: Set<RemappedVitalResource> {
    [delivered, failedEarlier]
  }

  func testRetryableFailureStatuses() {
    let retryable: [SyncProgress.SyncStatus] = [.error, .expectedError, .timedOut, .cancelled]
    let notRetryable: [SyncProgress.SyncStatus] = [
      .deprioritized, .started, .readChunk, .uploadedChunk, .noData, .completed,
      .revalidatingSyncState, .connectionPaused, .connectionDestroyed,
    ]

    XCTAssertTrue(retryable.allSatisfy(\.isRetryableFailure))
    XCTAssertFalse(notRetryable.contains(where: \.isRetryableFailure))
  }

  func testResourcesPendingRetryPicksActiveFailedResourcesNotJustDelivered() {
    let sleep = RemappedVitalResource(wrapped: .sleep)
    let workout = RemappedVitalResource(wrapped: .workout)
    let body = RemappedVitalResource(wrapped: .body)
    let heartRate = RemappedVitalResource(wrapped: .vitals(.heartRate))
    let steps = RemappedVitalResource(wrapped: .individual(.steps))

    let now = Date()
    let longAgo = now.addingTimeInterval(-failedSyncRetryInterval)
    let justNow = now.addingTimeInterval(-failedSyncRetryInterval + 1)

    var progress = SyncProgress()
    func record(_ resource: RemappedVitalResource, _ status: SyncProgress.SyncStatus, at date: Date) {
      var entry = SyncProgress.Resource()
      entry.syncs = [SyncProgress.Sync(start: date, status: status, tags: [])]
      progress.backfillTypes[resource.wrapped.backfillType] = entry
    }

    record(workout, .timedOut, at: longAgo)
    record(sleep, .expectedError, at: longAgo)
    record(body, .completed, at: longAgo)
    record(heartRate, .error, at: longAgo)
    record(steps, .cancelled, at: longAgo)
    record(failedEarlier, .error, at: justNow)

    let pending = resourcesPendingRetry(
      in: progress,
      // Steps failed but is no longer active. Glucose has never synced. Water failed too
      // recently to retry yet.
      activeResources: [sleep, workout, body, heartRate, delivered, failedEarlier],
      excluding: [heartRate],
      now: now
    )

    // Sleep precedes workouts in sync priority.
    XCTAssertEqual(pending, [sleep, workout])
  }

  func testDeliveryRetriesResourceThatFailedWhileLocked() async throws {
    let reads = ReadRecorder()
    let locked = Flag(true)
    let client = try makeClient(reads: reads, locked: locked)

    // Water changes while the phone is locked. The read fails and the delivery is spent.
    await client.syncDelivered([failedEarlier], activeResources: activeResources, concurrently: false)
    XCTAssertEqual(reads.count(for: failedEarlier), 1)
    XCTAssertEqual(lastStatus(of: failedEarlier), .expectedError)

    // A delivery for another resource arrives while the phone is still locked. It fails
    // too, so the earlier failure is not retried.
    await client.syncDelivered([delivered], activeResources: activeResources, concurrently: false)
    XCTAssertEqual(reads.count(for: failedEarlier), 1)

    // The same delivery with the phone unlocked goes through, but water failed too
    // recently to be retried yet.
    locked.value = false
    await client.syncDelivered([delivered], activeResources: activeResources, concurrently: false)
    XCTAssertEqual(reads.count(for: failedEarlier), 1)

    // A later delivery takes water with it.
    let later = Date().addingTimeInterval(failedSyncRetryInterval)
    await client.syncDelivered([delivered], activeResources: activeResources, concurrently: false, now: later)
    XCTAssertEqual(reads.count(for: failedEarlier), 2)
    XCTAssertEqual(lastStatus(of: failedEarlier), .completed)

    // Nothing is pending any more, so a further delivery syncs only what it names.
    await client.syncDelivered([delivered], activeResources: activeResources, concurrently: true, now: later)
    XCTAssertEqual(reads.count(for: failedEarlier), 2)
    XCTAssertEqual(reads.count(for: delivered), 4)
  }

  // MARK: - Fixtures

  private func lastStatus(of resource: RemappedVitalResource) -> SyncProgress.SyncStatus? {
    SyncProgressStore.shared.get()
      .backfillTypes[resource.wrapped.backfillType]?.latestSync?.lastStatus
  }

  private func makeClient(reads: ReadRecorder, locked: Flag) throws -> VitalHealthKitClient {
    let storage = VitalHealthKitStorage(storage: .debug)
    let chunkSizes = UserSDKHealthKitQueryChunkSizes(
      timeseries: 1, electrocardiogram: 1, workout: 1, sleep: 0, activityTimeseries: 1
    )

    // A valid cached state, so the sync does not ask the backend for one.
    try storage.setLocalSyncState(
      LocalSyncState(
        status: .active,
        historicalStageAnchor: Date(),
        defaultDaysToBackfill: 30,
        teamDataPullPreferences: nil,
        ingestionStart: .distantPast,
        ingestionEnd: nil,
        perDeviceActivityTS: false,
        expiresAt: Date().addingTimeInterval(3600),
        reportingInterval: nil,
        params: UserSDKHealthKitParams(
          queryChunkSizesBackground: chunkSizes,
          queryChunkSizesForeground: chunkSizes,
          workoutStream: false,
          workoutHeartRate: false
        )
      )
    )

    let activeResources = Set(self.activeResources.map(\.wrapped))

    var store = VitalHealthKitStore.debug
    store.authorizationState = { resources in
      (Dictionary(uniqueKeysWithValues: resources.map { ($0, activeResources.contains($0)) }), [:], [])
    }
    store.readResource = { resource, _, _, _ in
      reads.record(resource)

      if locked.value {
        throw HKError(.errorDatabaseInaccessible)
      }

      let sample = LocalQuantitySample(value: 1, date: Date(), unit: .glucose)
      let anchor = StoredAnchor(key: "retry-test-\(resource)", anchor: nil, date: Date(), vitalAnchors: nil)

      switch resource.wrapped {
      case .nutrition(.water):
        return (.timeSeries(.nutrition(.water([sample]))), [anchor])
      default:
        return (.timeSeries(.glucose([sample])), [anchor])
      }
    }

    var vitalClient = VitalClientProtocol.debug
    vitalClient.sdkStartHistoricalStage = { _ in }
    vitalClient.post = { _, _, _, _, _ in }

    return VitalHealthKitClient(
      configuration: .init(value: .init()),
      store: store,
      storage: storage,
      secureStorage: .init(keychain: .debug),
      vitalClient: vitalClient
    )
  }
}

private final class ReadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [RemappedVitalResource: Int] = [:]

  func record(_ resource: RemappedVitalResource) {
    lock.withLock { counts[resource, default: 0] += 1 }
  }

  func count(for resource: RemappedVitalResource) -> Int {
    lock.withLock { counts[resource, default: 0] }
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool

  init(_ value: Bool) {
    self.stored = value
  }

  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
