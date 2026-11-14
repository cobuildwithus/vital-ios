import XCTest
import HealthKit
import Foundation

@testable import VitalHealthKit
@_spi(VitalSDKInternals) @testable import VitalCore

/// A sync that fails because the phone is locked must be retried by the next delivery
/// that gets through, even when that delivery is for a different resource.
class VitalHealthKitRetryTests: XCTestCase {

  private let glucose = RemappedVitalResource(wrapped: .vitals(.glucose))
  private let water = RemappedVitalResource(wrapped: .nutrition(.water))
  private let caffeine = RemappedVitalResource(wrapped: .nutrition(.caffeine))
  private let bloodOxygen = RemappedVitalResource(wrapped: .vitals(.bloodOxygen))
  private let heartRateVariability = RemappedVitalResource(wrapped: .vitals(.heartRateVariability))
  private let respiratoryRate = RemappedVitalResource(wrapped: .vitals(.respiratoryRate))

  /// Sync progress is one store for the whole process. Start each test from an empty one.
  override func setUp() {
    super.setUp()
    SyncProgressStore.shared.clear()
  }

  override func tearDown() {
    SyncProgressStore.shared.clear()
    super.tearDown()
  }

  // MARK: - Which syncs are pending

  func testRetryableFailureStatuses() {
    let retryable: [SyncProgress.SyncStatus] = [.error, .expectedError, .timedOut, .cancelled]
    let notRetryable: [SyncProgress.SyncStatus] = [
      .deprioritized, .started, .readChunk, .uploadedChunk, .noData, .completed,
      .revalidatingSyncState, .connectionPaused, .connectionDestroyed,
    ]

    XCTAssertTrue(retryable.allSatisfy(\.isRetryableFailure))
    XCTAssertFalse(notRetryable.contains(where: \.isRetryableFailure))
  }

  func testSyncDidNotFinish() {
    func recorded(_ statuses: SyncProgress.SyncStatus...) -> SyncProgress.Sync {
      var sync = SyncProgress.Sync(start: Date(), status: statuses[0], tags: [])
      statuses.dropFirst().forEach { sync.append($0) }
      return sync
    }

    XCTAssertFalse(recorded(.started, .readChunk, .uploadedChunk, .completed).didNotFinish)
    XCTAssertFalse(recorded(.started, .noData).didNotFinish)

    // Waiting for its turn in the historical stage, not failed.
    XCTAssertFalse(recorded(.deprioritized).didNotFinish)

    XCTAssertTrue(recorded(.started, .expectedError).didNotFinish)
    XCTAssertTrue(recorded(.started, .readChunk, .timedOut).didNotFinish)
    XCTAssertTrue(recorded(.started, .connectionPaused).didNotFinish)

    // A failure followed by the progress of an upload that finished after it.
    XCTAssertTrue(recorded(.started, .readChunk, .error, .uploadedChunk).didNotFinish)

    // Cancelled or killed before anything else could be recorded.
    XCTAssertTrue(recorded(.started, .readChunk, .readChunk).didNotFinish)
    XCTAssertTrue(recorded(.started).didNotFinish)
  }

  func testResourcesPendingRetry() {
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
    record(water, .error, at: justNow)
    record(caffeine, .readChunk, at: longAgo)
    record(bloodOxygen, .readChunk, at: longAgo)

    let pending = resourcesPendingRetry(
      in: progress,
      // Steps failed but is no longer active. Glucose has never synced. Water failed too
      // recently to retry yet. Caffeine stopped part way and is not running. Blood oxygen
      // looks the same but is running right now.
      activeResources: [sleep, workout, body, heartRate, glucose, water, caffeine, bloodOxygen],
      excluding: [heartRate],
      syncing: [bloodOxygen.wrapped],
      now: now
    )

    // Sleep precedes workouts and caffeine in sync priority.
    XCTAssertEqual(pending.first, sleep)
    XCTAssertEqual(Set(pending), [sleep, workout, caffeine])
  }

  // MARK: - A delivery

  func testDeliveryRetriesResourceThatFailedWhileLocked() async throws {
    let phone = Phone()
    let active: Set<RemappedVitalResource> = [glucose, water]
    let client = try makeClient(phone, active: active)

    // Water changes while the phone is locked. The read fails and the delivery is spent.
    phone.locked = true
    await client.syncDelivered([water], activeResources: active, concurrently: false, acknowledge: {})
    XCTAssertEqual(phone.reads(of: water), 1)
    XCTAssertEqual(lastStatus(of: water), .expectedError)

    // A delivery for another resource arrives while the phone is still locked. It fails
    // too, so the earlier failure is not retried.
    let later = Date().addingTimeInterval(failedSyncRetryInterval)
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})
    XCTAssertEqual(phone.reads(of: water), 1)

    // The phone is unlocked, but water failed too recently to be retried yet.
    phone.locked = false
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, acknowledge: {})
    XCTAssertEqual(phone.reads(of: water), 1)

    // A later delivery takes water with it.
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})
    XCTAssertEqual(phone.reads(of: water), 2)
    XCTAssertEqual(lastStatus(of: water), .completed)

    // Nothing is pending any more, so a further delivery syncs only what it names.
    await client.syncDelivered([glucose], activeResources: active, concurrently: true, now: later, acknowledge: {})
    XCTAssertEqual(phone.reads(of: water), 2)
    XCTAssertEqual(phone.reads(of: glucose), 4)
  }

  /// HealthKit is waiting for its answer, not for the retries.
  func testDeliveryIsAcknowledgedOnceAndBeforeRetries() async throws {
    let phone = Phone()
    let active: Set<RemappedVitalResource> = [glucose, water]
    let client = try makeClient(phone, active: active)

    phone.locked = true
    await client.syncDelivered([water], activeResources: active, concurrently: false) {
      phone.record("acknowledged")
    }
    XCTAssertEqual(phone.events, ["read water", "acknowledged"], "a failed delivery is acknowledged too")

    phone.locked = false
    phone.clearEvents()
    let later = Date().addingTimeInterval(failedSyncRetryInterval)
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later) {
      phone.record("acknowledged")
    }

    XCTAssertEqual(
      phone.events,
      ["read glucose", "post glucose", "acknowledged", "read water", "post water"]
    )
  }

  /// The listener's own path: every payload's completion handler runs exactly once, and
  /// before the retries start.
  func testProcessCompletesEachPayloadOnceBeforeRetries() async throws {
    let phone = Phone()
    let active: Set<RemappedVitalResource> = [glucose, water, caffeine]
    let client = try makeClient(phone, active: active)

    func payload(_ name: String, _ resources: [RemappedVitalResource]) -> BackgroundDeliveryPayload {
      BackgroundDeliveryPayload(resources: resources) { completion in
        XCTAssertEqual(completion, .completed)
        phone.record("completed \(name)")
      }
    }

    // A locked phone: nothing syncs, both handlers still run once.
    phone.locked = true
    await client.process([payload("a", [water]), payload("b", [water, caffeine])], activeResources: active)
    XCTAssertEqual(phone.events.filter { $0.hasPrefix("completed") }, ["completed a", "completed b"])
    XCTAssertEqual(Array(phone.events.suffix(2)), ["completed a", "completed b"])

    // Unlocked: glucose syncs, the handlers run, then water and caffeine are retried.
    phone.locked = false
    phone.clearEvents()
    let later = Date().addingTimeInterval(failedSyncRetryInterval)
    await client.process([payload("c", [glucose]), payload("d", [glucose])], activeResources: active, now: later)

    XCTAssertEqual(
      Array(phone.events.prefix(4)),
      ["read glucose", "post glucose", "completed c", "completed d"]
    )
    XCTAssertEqual(
      Set(phone.events.dropFirst(4)),
      ["read water", "post water", "read caffeine", "post caffeine"]
    )
    XCTAssertEqual(phone.events.count, 8)
  }

  func testDeliveryRetriesAtMostThreeResourcesHighestPriorityFirst() async throws {
    let pending = [water, caffeine, bloodOxygen, heartRateVariability, respiratoryRate]
    let active = Set(pending + [glucose])
    let phone = Phone()
    let client = try makeClient(phone, active: active)

    phone.locked = true
    await client.syncDelivered(Set(pending), activeResources: active, concurrently: false, acknowledge: {})
    XCTAssertTrue(pending.allSatisfy { phone.reads(of: $0) == 1 })

    phone.locked = false
    let later = Date().addingTimeInterval(failedSyncRetryInterval)
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})

    let retried = pending.filter { phone.reads(of: $0) == 2 }
    XCTAssertEqual(maxRetriesPerDelivery, 3)
    XCTAssertEqual(retried.count, maxRetriesPerDelivery)

    // Water and caffeine come before the vitals in sync priority.
    XCTAssertTrue(retried.contains(water))
    XCTAssertTrue(retried.contains(caffeine))

    // The next delivery takes the rest.
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})
    XCTAssertTrue(pending.allSatisfy { phone.reads(of: $0) == 2 })
    XCTAssertTrue(pending.allSatisfy { lastStatus(of: $0) == .completed })
  }

  /// A delivery with nothing new completes without touching the backend, so it says
  /// nothing about whether the backend can be reached. It must not set off retries.
  func testDeliveryWithNothingToUploadDoesNotRetry() async throws {
    let phone = Phone()
    let active: Set<RemappedVitalResource> = [glucose, water]
    let client = try makeClient(phone, active: active)

    phone.locked = true
    await client.syncDelivered([water], activeResources: active, concurrently: false, acknowledge: {})

    // Unlocked but offline, and glucose has nothing new.
    phone.locked = false
    phone.offline = true
    phone.nothingNew = [glucose]
    let later = Date().addingTimeInterval(failedSyncRetryInterval)

    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})

    XCTAssertEqual(lastStatus(of: glucose), .completed)
    XCTAssertEqual(phone.reads(of: water), 1, "water must not be retried")
    XCTAssertEqual(phone.posts(of: water), 0)

    // Back online with something to upload: the delivery proves the path and water follows.
    phone.offline = false
    phone.nothingNew = []
    await client.syncDelivered([glucose], activeResources: active, concurrently: false, now: later, acknowledge: {})

    XCTAssertEqual(phone.reads(of: water), 2)
    XCTAssertEqual(phone.posts(of: water), 1)
    XCTAssertEqual(lastStatus(of: water), .completed)
  }

  // MARK: - Fixtures

  private func lastStatus(of resource: RemappedVitalResource) -> SyncProgress.SyncStatus? {
    SyncProgressStore.shared.get()
      .backfillTypes[resource.wrapped.backfillType]?.latestSync?.lastStatus
  }

  /// A client in the daily stage for every active resource. Each read returns one new
  /// sample unless the phone says otherwise.
  private func makeClient(_ phone: Phone, active: Set<RemappedVitalResource>) throws -> VitalHealthKitClient {
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
    active.forEach(storage.markHistoricalStageDone(for:))

    let activeResources = Set(active.map(\.wrapped))

    var store = VitalHealthKitStore.debug
    store.authorizationState = { resources in
      (Dictionary(uniqueKeysWithValues: resources.map { ($0, activeResources.contains($0)) }), [:], [])
    }
    store.readResource = { resource, _, _, _ in
      phone.record("read \(Phone.name(of: resource))")

      if phone.locked {
        throw HKError(.errorDatabaseInaccessible)
      }
      if phone.nothingNew.contains(resource) {
        return (nil, [])
      }

      let sample = LocalQuantitySample(value: 1, date: Date(), unit: .glucose)
      let anchor = StoredAnchor(key: "retry-test-\(resource)", anchor: nil, date: Date(), vitalAnchors: nil)
      return (.timeSeries(Phone.payload(for: resource, [sample])), [anchor])
    }

    var vitalClient = VitalClientProtocol.debug
    vitalClient.post = { data, _, _, _, _ in
      if phone.offline {
        throw URLError(.notConnectedToInternet)
      }
      phone.record("post \(Phone.name(of: data))")
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

/// What the tests control about the phone, and what the client did to it, in order.
private final class Phone: @unchecked Sendable {
  private let lock = NSLock()
  private var _locked = false
  private var _offline = false
  private var _nothingNew: Set<RemappedVitalResource> = []
  private var _events: [String] = []

  var locked: Bool {
    get { lock.withLock { _locked } }
    set { lock.withLock { _locked = newValue } }
  }

  var offline: Bool {
    get { lock.withLock { _offline } }
    set { lock.withLock { _offline = newValue } }
  }

  var nothingNew: Set<RemappedVitalResource> {
    get { lock.withLock { _nothingNew } }
    set { lock.withLock { _nothingNew = newValue } }
  }

  var events: [String] {
    lock.withLock { _events }
  }

  func record(_ event: String) {
    lock.withLock { _events.append(event) }
  }

  func clearEvents() {
    lock.withLock { _events = [] }
  }

  func reads(of resource: RemappedVitalResource) -> Int {
    events.filter { $0 == "read \(Self.name(of: resource))" }.count
  }

  func posts(of resource: RemappedVitalResource) -> Int {
    events.filter { $0 == "post \(Self.name(of: resource))" }.count
  }

  static func name(of resource: RemappedVitalResource) -> String {
    switch resource.wrapped {
    case .nutrition(.water):
      return "water"
    case .nutrition(.caffeine):
      return "caffeine"
    case .vitals(.bloodOxygen):
      return "blood oxygen"
    case .vitals(.heartRateVariability):
      return "heart rate variability"
    case .vitals(.respiratoryRate):
      return "respiratory rate"
    default:
      return "glucose"
    }
  }

  static func name(of data: ProcessedResourceData) -> String {
    switch data {
    case .timeSeries(.nutrition(.water)):
      return "water"
    case .timeSeries(.nutrition(.caffeine)):
      return "caffeine"
    case .timeSeries(.bloodOxygen):
      return "blood oxygen"
    case .timeSeries(.heartRateVariability):
      return "heart rate variability"
    case .timeSeries(.respiratoryRate):
      return "respiratory rate"
    default:
      return "glucose"
    }
  }

  static func payload(for resource: RemappedVitalResource, _ samples: [LocalQuantitySample]) -> TimeSeriesData {
    switch resource.wrapped {
    case .nutrition(.water):
      return .nutrition(.water(samples))
    case .nutrition(.caffeine):
      return .nutrition(.caffeine(samples))
    case .vitals(.bloodOxygen):
      return .bloodOxygen(samples)
    case .vitals(.heartRateVariability):
      return .heartRateVariability(samples)
    case .vitals(.respiratoryRate):
      return .respiratoryRate(samples)
    default:
      return .glucose(samples)
    }
  }
}
