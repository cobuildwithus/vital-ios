import XCTest
import HealthKit
import Foundation

@testable import VitalHealthKit
@_spi(VitalSDKInternals) @testable import VitalCore

/// Drives `VitalHealthKitClient.sync` through its store and API client seams with a
/// resource that is read and uploaded in three chunks.
class VitalHealthKitSyncPipelineTests: XCTestCase {

  private let resource = RemappedVitalResource(wrapped: .vitals(.glucose))
  private let anchorKey = "sync-pipeline-test"

  /// The pipeline reads chunk 2 while chunk 1 uploads. When the upload of chunk 1 fails,
  /// the waiting upload of chunk 2 must not go out: its anchors sit past chunk 1, so
  /// committing them would mean chunk 1 is never read again.
  func testFailedChunkUploadIsNotSkippedByQueuedLaterChunk() async throws {
    let storage = try makeStorage()
    let posts = Recorder()
    let secondChunkRead = Gate()
    let failFirstChunk = Switch(true)

    let client = makeClient(
      storage: storage,
      afterRead: { chunk in
        if chunk == 2 { secondChunkRead.open() }
      },
      post: { chunk in
        posts.append(chunk)

        if chunk == 1 && failFirstChunk.value {
          // Fail only once chunk 2 has been read and its upload is waiting behind this one.
          await secondChunkRead.wait()
          try await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
          throw URLError(.networkConnectionLost)
        }
      }
    )

    await client.sync(resource, [.manual])

    XCTAssertEqual(posts.values, [1], "chunk 2 must not be uploaded after chunk 1 failed")
    XCTAssertNil(storage.read(key: anchorKey), "no anchor may be committed past the failed chunk")
    XCTAssertFalse(storage.historicalStageDone(for: resource))

    // The next sync starts again from the failed chunk and loses nothing.
    failFirstChunk.value = false
    await client.sync(resource, [.manual])

    XCTAssertEqual(posts.values, [1, 1, 2, 3])
    XCTAssertEqual(storage.read(key: anchorKey)?.date, chunkDate(3))
    XCTAssertTrue(storage.historicalStageDone(for: resource))
  }

  /// A failed read says nothing about the chunk already uploading, which precedes it.
  /// That upload is left to finish and commits its own anchors.
  func testFailedReadLeavesInFlightUploadToCommit() async throws {
    let storage = try makeStorage()
    let posts = Recorder()
    let secondChunkReadFailed = Gate()

    let client = makeClient(
      storage: storage,
      beforeRead: { chunk in
        if chunk == 2 {
          secondChunkReadFailed.open()
          throw HKError(.errorDatabaseInaccessible)
        }
      },
      post: { chunk in
        posts.append(chunk)

        if chunk == 1 {
          await secondChunkReadFailed.wait()
          try await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        }
      }
    )

    await client.sync(resource, [.manual])

    XCTAssertEqual(posts.values, [1])
    XCTAssertEqual(storage.read(key: anchorKey)?.date, chunkDate(1))
    XCTAssertFalse(storage.historicalStageDone(for: resource))

    // The upload finished after the read failed. The failure must still be the last
    // status recorded, or the sync looks like it is still in progress.
    let latestSync = SyncProgressStore.shared.get()
      .backfillTypes[resource.wrapped.backfillType]?.latestSync
    XCTAssertEqual(latestSync?.lastStatus, .expectedError)
  }

  // MARK: - Fixtures

  private func chunkDate(_ chunk: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(chunk))
  }

  private func makeStorage() throws -> VitalHealthKitStorage {
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

    return storage
  }

  /// A client whose only active resource yields chunks 1, 2 and 3 in order. Each read
  /// continues from the anchor of the chunk before it, as the real readers do.
  private func makeClient(
    storage: VitalHealthKitStorage,
    beforeRead: @escaping @Sendable (Int) throws -> Void = { _ in },
    afterRead: @escaping @Sendable (Int) -> Void = { _ in },
    post: @escaping @Sendable (Int) async throws -> Void
  ) -> VitalHealthKitClient {
    let activeResource = resource.wrapped
    let anchorKey = self.anchorKey
    let chunkDate = self.chunkDate

    var store = VitalHealthKitStore.debug
    store.authorizationState = { resources in
      (Dictionary(uniqueKeysWithValues: resources.map { ($0, $0 == activeResource) }), [:], [])
    }
    store.readResource = { _, _, anchorStorage, _ in
      let previous = anchorStorage.read(key: anchorKey)?.date?.timeIntervalSince1970 ?? 0
      let chunk = Int(previous) + 1
      try beforeRead(chunk)

      let sample = LocalQuantitySample(value: Double(chunk), date: chunkDate(chunk), unit: .glucose)
      let anchor = StoredAnchor(
        key: anchorKey,
        anchor: nil,
        date: chunkDate(chunk),
        vitalAnchors: nil,
        hasMore: chunk < 3
      )

      afterRead(chunk)
      return (.timeSeries(.glucose([sample])), [anchor])
    }

    var vitalClient = VitalClientProtocol.debug
    vitalClient.sdkStartHistoricalStage = { _ in }
    vitalClient.post = { data, _, _, _, _ in
      guard case let .timeSeries(.glucose(samples)) = data, let sample = samples.first else {
        return XCTFail("unexpected payload")
      }
      try await post(Int(sample.value))
    }

    return VitalHealthKitClient(
      configuration: .init(value: .init()),
      store: store,
      storage: storage,
      secureStorage: .init(keychain: .debug),
      vitalClient: vitalClient
    )
  }
}

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Int] = []

  func append(_ value: Int) {
    lock.withLock { recorded.append(value) }
  }

  var values: [Int] {
    lock.withLock { recorded }
  }
}

private final class Switch: @unchecked Sendable {
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

private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false

  func open() {
    lock.withLock { opened = true }
  }

  func wait() async {
    while lock.withLock({ opened }) == false {
      try? await Task.sleep(nanoseconds: 5 * NSEC_PER_MSEC)
    }
  }
}
