import Foundation
import SQLite3
import XCTest
@testable import UsageCore

final class SQLiteUsageRepositoryTests: XCTestCase {
    func testMigratesEmptyVersionZeroDatabase() async throws {
        let url = try makeDatabaseURL()
        let repository = try SQLiteUsageRepository(url: url)

        let totals = try await repository.applicationTotals(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(totals, [])
        XCTAssertEqual(try readUserVersion(at: url), SQLiteUsageRepository.schemaVersion)
    }

    func testMigratesVersionOneAndPreservesRowsAsUnknownCarrier() async throws {
        let url = try makeDatabaseURL()
        try createVersionOneDatabase(at: url)

        let repository = try SQLiteUsageRepository(url: url)
        let totals = try await repository.applicationTotals(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(totals, [
            ApplicationUsageTotal(
                applicationIdentifier: "legacy.app",
                carrier: .unknown,
                bytes: UsageBytes(downloadedBytes: 10, uploadedBytes: 2)
            )
        ])
        XCTAssertEqual(try readUserVersion(at: url), SQLiteUsageRepository.schemaVersion)
    }

    func testImportsLegacyDatabaseExactlyOnce() async throws {
        let destinationURL = try makeDatabaseURL()
        let sourceURL = try makeDatabaseURL()
        try createVersionOneDatabase(at: sourceURL)
        let repository = try SQLiteUsageRepository(url: destinationURL)

        let firstImport = try await repository.importLegacyDatabase(at: sourceURL)
        XCTAssertEqual(
            firstImport,
            LegacyDatabaseImportSummary(physicalSamples: 0, applicationSamples: 1, plans: 0)
        )
        let secondImport = try await repository.importLegacyDatabase(at: sourceURL)
        XCTAssertEqual(
            secondImport,
            LegacyDatabaseImportSummary(physicalSamples: 0, applicationSamples: 0, plans: 0)
        )
        let importedTotals = try await repository.applicationTotals(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertEqual(
            importedTotals,
            [
                ApplicationUsageTotal(
                    applicationIdentifier: "legacy.app",
                    carrier: .unknown,
                    bytes: UsageBytes(downloadedBytes: 10, uploadedBytes: 2)
                )
            ]
        )
    }

    func testImportsLegacyPhysicalRowsWithStableNetworkIDsExactlyOnce() async throws {
        let destinationURL = try makeDatabaseURL()
        let sourceURL = try makeDatabaseURL()
        try createVersionThreeDatabase(at: sourceURL)
        let repository = try SQLiteUsageRepository(url: destinationURL)

        let firstImport = try await repository.importLegacyDatabase(at: sourceURL)
        XCTAssertEqual(
            firstImport,
            LegacyDatabaseImportSummary(physicalSamples: 6, applicationSamples: 0, plans: 0)
        )
        let secondImport = try await repository.importLegacyDatabase(at: sourceURL)
        XCTAssertEqual(
            secondImport,
            LegacyDatabaseImportSummary(physicalSamples: 0, applicationSamples: 0, plans: 0)
        )

        let samples = try await repository.physicalSamples(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        ))
        let totals = totalsByNetwork(in: samples)
        let homeID = WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: "Home|5G")
        let unidentifiedEn0ID = WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: nil)
        let unidentifiedEn1ID = WiFiNetworkIdentifier.make(interfaceName: "en1", ssid: nil)

        XCTAssertEqual(samples.count, 6)
        XCTAssertEqual(totals[homeID], UsageBytes(downloadedBytes: 300, uploadedBytes: 15))
        XCTAssertEqual(totals[unidentifiedEn0ID], UsageBytes(downloadedBytes: 150, uploadedBytes: 6))
        XCTAssertEqual(totals[unidentifiedEn1ID], UsageBytes(downloadedBytes: 7, uploadedBytes: 3))
        XCTAssertEqual(try physicalTotalsByNetwork(at: destinationURL), totals)
        let knownNetworks = try await repository.knownWiFiNetworks()
        XCTAssertEqual(
            Set(knownNetworks.map(\.id)),
            [homeID, unidentifiedEn0ID, unidentifiedEn1ID]
        )
        XCTAssertEqual(
            try nullCount(in: "physical_samples", column: "wifi_network_id", at: destinationURL),
            0
        )
        XCTAssertEqual(try foreignKeyViolationCount(at: destinationURL), 0)
    }

    func testLegacyImportMergesExistingNetworkObservationWindow() async throws {
        let destinationURL = try makeDatabaseURL()
        let sourceURL = try makeDatabaseURL()
        try createVersionThreeDatabase(at: sourceURL)
        let repository = try SQLiteUsageRepository(url: destinationURL)
        let home = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "Home|5G")

        try await repository.save(physicalSample: PhysicalUsageSample(
            network: home,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 110),
            bytes: UsageBytes(downloadedBytes: 1, uploadedBytes: 1)
        ))
        _ = try await repository.importLegacyDatabase(at: sourceURL)

        let knownNetworks = try await repository.knownWiFiNetworks()
        let importedHome = try XCTUnwrap(
            knownNetworks.first { $0.id == home.networkID }
        )
        XCTAssertEqual(importedHome.firstSeenAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(importedHome.lastSeenAt, Date(timeIntervalSince1970: 110))
    }

    func testApplicationInsertIsIdempotentAndAggregatesByCarrier() async throws {
        let url = try makeDatabaseURL()
        let repository = try SQLiteUsageRepository(url: url)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        )
        let repeatedID = UUID()
        let samples = [
            ApplicationUsageSample(
                id: repeatedID,
                applicationIdentifier: "browser",
                carrier: .wifi,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                bytes: UsageBytes(downloadedBytes: 100, uploadedBytes: 5)
            ),
            ApplicationUsageSample(
                id: repeatedID,
                applicationIdentifier: "browser",
                carrier: .wifi,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                bytes: UsageBytes(downloadedBytes: 999, uploadedBytes: 999)
            ),
            ApplicationUsageSample(
                applicationIdentifier: "browser",
                carrier: .wifi,
                startedAt: Date(timeIntervalSince1970: 21),
                endedAt: Date(timeIntervalSince1970: 22),
                bytes: UsageBytes(downloadedBytes: 50, uploadedBytes: 2)
            ),
            ApplicationUsageSample(
                applicationIdentifier: "browser",
                carrier: .cellular,
                startedAt: Date(timeIntervalSince1970: 23),
                endedAt: Date(timeIntervalSince1970: 24),
                bytes: UsageBytes(downloadedBytes: 7, uploadedBytes: 3)
            )
        ]

        try await repository.save(applicationSamples: samples)
        let totals = try await repository.applicationTotals(in: interval)

        XCTAssertEqual(totals, [
            ApplicationUsageTotal(
                applicationIdentifier: "browser",
                carrier: .cellular,
                bytes: UsageBytes(downloadedBytes: 7, uploadedBytes: 3)
            ),
            ApplicationUsageTotal(
                applicationIdentifier: "browser",
                carrier: .wifi,
                bytes: UsageBytes(downloadedBytes: 150, uploadedBytes: 7)
            )
        ])
    }

    func testApplicationBucketsUpsertAndAggregateInSQLite() async throws {
        let url = try makeDatabaseURL()
        let repository = try SQLiteUsageRepository(url: url)
        let firstBucket = Date(timeIntervalSince1970: 300)
        let secondBucket = Date(timeIntervalSince1970: 600)

        try await repository.save(applicationBuckets: [
            ApplicationUsageBucket(
                applicationIdentifier: "browser",
                carrier: .wifi,
                bucketStart: firstBucket,
                endedAt: Date(timeIntervalSince1970: 310),
                bytes: UsageBytes(downloadedBytes: 100, uploadedBytes: 5)
            ),
            ApplicationUsageBucket(
                applicationIdentifier: "browser",
                carrier: .wifi,
                bucketStart: firstBucket,
                endedAt: Date(timeIntervalSince1970: 320),
                bytes: UsageBytes(downloadedBytes: 50, uploadedBytes: 2)
            ),
            ApplicationUsageBucket(
                applicationIdentifier: "browser",
                carrier: .wifi,
                bucketStart: secondBucket,
                endedAt: Date(timeIntervalSince1970: 610),
                bytes: UsageBytes(downloadedBytes: 20, uploadedBytes: 1)
            )
        ])

        let bucketTotals = try await repository.applicationTotals(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertEqual(
            bucketTotals,
            [
                ApplicationUsageTotal(
                    applicationIdentifier: "browser",
                    carrier: .wifi,
                    bytes: UsageBytes(downloadedBytes: 170, uploadedBytes: 8)
                )
            ]
        )
        XCTAssertEqual(
            try rowCount(in: "application_usage_buckets", at: url),
            2
        )
    }

    func testVersionTwoDatabaseOpensWithoutMigration() throws {
        let url = try makeDatabaseURL()
        _ = try SQLiteUsageRepository(url: url)
        _ = try SQLiteUsageRepository(url: url)
        XCTAssertEqual(try readUserVersion(at: url), SQLiteUsageRepository.schemaVersion)
    }

    func testMigratesVersionThreePhysicalRowsIntoStableWiFiNetworks() async throws {
        let url = try makeDatabaseURL()
        try createVersionThreeDatabase(at: url)

        let repository = try SQLiteUsageRepository(url: url)
        let networks = try await repository.knownWiFiNetworks()
        let samples = try await repository.physicalSamples(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        ))
        let homeID = WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: "Home|5G")
        let unidentifiedEn0ID = WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: nil)
        let unidentifiedEn1ID = WiFiNetworkIdentifier.make(interfaceName: "en1", ssid: nil)
        let networksByID = Dictionary(uniqueKeysWithValues: networks.map { ($0.id, $0) })
        let totals = totalsByNetwork(in: samples)

        XCTAssertEqual(samples.count, 6)
        XCTAssertEqual(networks.count, 3)
        XCTAssertEqual(
            Set(networks.map(\.id)),
            [homeID, unidentifiedEn0ID, unidentifiedEn1ID]
        )
        XCTAssertEqual(networksByID[homeID]?.firstSeenAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(networksByID[homeID]?.lastSeenAt, Date(timeIntervalSince1970: 70))
        XCTAssertEqual(networksByID[unidentifiedEn0ID]?.ssid, nil)
        XCTAssertEqual(
            networksByID[unidentifiedEn0ID]?.firstSeenAt,
            Date(timeIntervalSince1970: 21)
        )
        XCTAssertEqual(
            networksByID[unidentifiedEn0ID]?.lastSeenAt,
            Date(timeIntervalSince1970: 50)
        )
        XCTAssertEqual(totals[homeID], UsageBytes(downloadedBytes: 300, uploadedBytes: 15))
        XCTAssertEqual(totals[unidentifiedEn0ID], UsageBytes(downloadedBytes: 150, uploadedBytes: 6))
        XCTAssertEqual(totals[unidentifiedEn1ID], UsageBytes(downloadedBytes: 7, uploadedBytes: 3))
        XCTAssertEqual(try physicalTotalsByNetwork(at: url), totals)
        XCTAssertEqual(try nullCount(in: "physical_samples", column: "wifi_network_id", at: url), 0)
        XCTAssertEqual(try foreignKeyViolationCount(at: url), 0)
        XCTAssertEqual(try readUserVersion(at: url), SQLiteUsageRepository.schemaVersion)
    }

    func testWiFiNetworkIdentifierIsStableAndCollisionResistant() {
        let homeOnEn0 = WiFiNetworkIdentity(
            interfaceName: "en0",
            interfaceIndex: 11,
            ssid: "Home|5G"
        )
        let homeAfterInterfaceChange = WiFiNetworkIdentity(
            interfaceName: "en7",
            interfaceIndex: 999,
            ssid: "Home|5G"
        )

        XCTAssertEqual(homeOnEn0.networkID, homeAfterInterfaceChange.networkID)
        XCTAssertEqual(homeOnEn0.networkID, "ssid:v1:486f6d657c3547")
        let spacedHomeID = WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: " Home|5G ")
        XCTAssertEqual(spacedHomeID, homeOnEn0.networkID)
        XCTAssertEqual(
            Set([
                homeOnEn0.networkID,
                WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: "home|5g"),
                spacedHomeID,
                WiFiNetworkIdentifier.make(interfaceName: "en0", ssid: "家庭网络📶")
            ]).count,
            3
        )
    }

    func testUnidentifiedWiFiNetworkIdentifierUsesStableInterfaceName() {
        let missingSSID = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: nil)
        let emptySSID = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "")
        let changedIndex = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 42, ssid: nil)
        let otherInterface = WiFiNetworkIdentity(interfaceName: "en1", interfaceIndex: 11, ssid: nil)

        XCTAssertEqual(missingSSID.networkID, emptySSID.networkID)
        XCTAssertEqual(missingSSID.networkID, changedIndex.networkID)
        XCTAssertNotEqual(missingSSID.networkID, otherInterface.networkID)
        XCTAssertEqual(missingSSID.networkID, "unidentified:v1:656e30")
    }

    func testPhysicalSamplesAggregateByStableWiFiNetworkAndInterval() async throws {
        let url = try makeDatabaseURL()
        let repository = try SQLiteUsageRepository(url: url)
        let homeOnEn0 = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "Home")
        let homeOnEn7 = WiFiNetworkIdentity(interfaceName: "en7", interfaceIndex: 99, ssid: "Home")
        let office = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "Office")

        try await repository.save(physicalSample: PhysicalUsageSample(
            network: homeOnEn0,
            startedAt: Date(timeIntervalSince1970: 90),
            endedAt: Date(timeIntervalSince1970: 101),
            bytes: UsageBytes(downloadedBytes: 1_000, uploadedBytes: 1_000)
        ))
        try await repository.save(physicalSample: PhysicalUsageSample(
            network: homeOnEn0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            bytes: UsageBytes(downloadedBytes: 100, uploadedBytes: 5)
        ))
        try await repository.save(physicalSample: PhysicalUsageSample(
            network: homeOnEn7,
            startedAt: Date(timeIntervalSince1970: 21),
            endedAt: Date(timeIntervalSince1970: 30),
            bytes: UsageBytes(downloadedBytes: 50, uploadedBytes: 2)
        ))
        try await repository.save(physicalSample: PhysicalUsageSample(
            network: office,
            startedAt: Date(timeIntervalSince1970: 31),
            endedAt: Date(timeIntervalSince1970: 40),
            bytes: UsageBytes(downloadedBytes: 7, uploadedBytes: 3)
        ))

        let samples = try await repository.physicalSamples(in: DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        ))
        let totals = totalsByNetwork(in: samples)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(
            totals[homeOnEn0.networkID],
            UsageBytes(downloadedBytes: 150, uploadedBytes: 7)
        )
        XCTAssertEqual(
            totals[office.networkID],
            UsageBytes(downloadedBytes: 7, uploadedBytes: 3)
        )

        let networksByID = Dictionary(
            uniqueKeysWithValues: try await repository.knownWiFiNetworks().map { ($0.id, $0) }
        )
        XCTAssertEqual(networksByID.count, 2)
        XCTAssertEqual(
            networksByID[homeOnEn0.networkID]?.firstSeenAt,
            Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            networksByID[homeOnEn0.networkID]?.lastSeenAt,
            Date(timeIntervalSince1970: 101)
        )
    }

    func testWiFiPlanAssignmentsPersistAndPlanUpdatesDoNotRemoveThem() async throws {
        let url = try makeDatabaseURL()
        let repository = try SQLiteUsageRepository(url: url)
        let home = KnownWiFiNetwork(
            identity: WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "Home")
        )
        let office = KnownWiFiNetwork(
            identity: WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "Office")
        )
        let planID = UUID()
        let originalPlan = makePlan(id: planID, name: "家庭宽带")
        let renamedPlan = makePlan(id: planID, name: "家庭网络")

        try await repository.save(wifiNetwork: home)
        try await repository.save(wifiNetwork: office)
        try await repository.save(plan: originalPlan)
        try await repository.setPlan(planID, forWiFiNetwork: home.id)
        try await repository.save(plan: renamedPlan)

        let assignments = try await repository.wifiPlanAssignments()
        let savedPlans = try await repository.plans()
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments.first?.networkID, home.id)
        XCTAssertEqual(assignments.first?.planID, planID)
        XCTAssertEqual(savedPlans.first?.name, "家庭网络")

        let reopenedRepository = try SQLiteUsageRepository(url: url)
        let persistedAssignments = try await reopenedRepository.wifiPlanAssignments()
        let persistedPlans = try await reopenedRepository.plans()
        XCTAssertEqual(persistedAssignments.count, 1)
        XCTAssertEqual(persistedAssignments.first?.networkID, home.id)
        XCTAssertEqual(persistedAssignments.first?.planID, planID)
        XCTAssertEqual(persistedPlans.first?.name, "家庭网络")

        try await repository.setPlan(nil, forWiFiNetwork: home.id)
        let assignmentsAfterRemoval = try await repository.wifiPlanAssignments()
        let networksAfterRemoval = try await repository.knownWiFiNetworks()
        XCTAssertTrue(assignmentsAfterRemoval.isEmpty)
        XCTAssertEqual(Set(networksAfterRemoval.map(\.id)), [home.id, office.id])
    }

    func testWiFiPlanAssignmentRejectsUnknownPlanAndNetwork() async throws {
        let url = try makeDatabaseURL()
        let repository = try SQLiteUsageRepository(url: url)
        let network = KnownWiFiNetwork(
            identity: WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 11, ssid: "Home")
        )
        try await repository.save(wifiNetwork: network)

        await XCTAssertThrowsErrorAsync {
            try await repository.setPlan(UUID(), forWiFiNetwork: network.id)
        }
        try await repository.save(plan: makePlan(name: "家庭宽带"))
        let plans = try await repository.plans()
        let planID = try XCTUnwrap(plans.first?.id)
        try await repository.setPlan(planID, forWiFiNetwork: network.id)
        await XCTAssertThrowsErrorAsync {
            try await repository.setPlan(UUID(), forWiFiNetwork: network.id)
        }
        let assignmentsAfterRejectedUpdate = try await repository.wifiPlanAssignments()
        XCTAssertEqual(assignmentsAfterRejectedUpdate.count, 1)
        XCTAssertEqual(assignmentsAfterRejectedUpdate.first?.networkID, network.id)
        XCTAssertEqual(assignmentsAfterRejectedUpdate.first?.planID, planID)
        await XCTAssertThrowsErrorAsync {
            try await repository.setPlan(planID, forWiFiNetwork: "ssid:v1:missing")
        }
        XCTAssertEqual(try foreignKeyViolationCount(at: url), 0)
    }

    func testRejectsFutureSchemaVersion() throws {
        let url = try makeDatabaseURL()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("Failed to open SQLite database") }
        sqlite3_exec(database, "PRAGMA user_version = 99;", nil, nil, nil)
        sqlite3_close(database)

        XCTAssertThrowsError(try SQLiteUsageRepository(url: url)) { error in
            XCTAssertTrue(String(describing: error).contains("newer than supported"))
        }
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiFiUsageSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func createVersionOneDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE application_samples (
            id TEXT PRIMARY KEY NOT NULL,
            application_identifier TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            uploaded_bytes INTEGER NOT NULL
        );
        INSERT INTO application_samples VALUES
            ('00000000-0000-0000-0000-000000000001', 'legacy.app', 10, 20, 10, 2);
        PRAGMA user_version = 1;
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func createVersionThreeDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE physical_samples (
            id TEXT PRIMARY KEY NOT NULL,
            interface_name TEXT NOT NULL,
            interface_index INTEGER NOT NULL,
            ssid TEXT,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            uploaded_bytes INTEGER NOT NULL
        );
        CREATE TABLE application_samples (
            id TEXT PRIMARY KEY NOT NULL,
            application_identifier TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            uploaded_bytes INTEGER NOT NULL,
            carrier TEXT NOT NULL DEFAULT 'unknown'
        );
        CREATE TABLE application_usage_buckets (
            application_identifier TEXT NOT NULL,
            carrier TEXT NOT NULL,
            bucket_start REAL NOT NULL,
            ended_at REAL NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            uploaded_bytes INTEGER NOT NULL,
            PRIMARY KEY (bucket_start, application_identifier, carrier)
        );
        CREATE TABLE usage_plans (
            id TEXT PRIMARY KEY NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE TABLE migration_state (
            key TEXT PRIMARY KEY NOT NULL,
            completed_at REAL NOT NULL
        );
        INSERT INTO physical_samples VALUES
            ('00000000-0000-0000-0000-000000000010', 'en0', 11, 'Home|5G', 10, 20, 100, 5),
            ('00000000-0000-0000-0000-000000000011', 'en0', 11, NULL, 21, 30, 50, 2),
            ('00000000-0000-0000-0000-000000000012', 'en0', 12, '', 31, 40, 25, 1),
            ('00000000-0000-0000-0000-000000000013', 'en0', 99, NULL, 41, 50, 75, 3),
            ('00000000-0000-0000-0000-000000000014', 'en1', 7, NULL, 51, 60, 7, 3),
            ('00000000-0000-0000-0000-000000000015', 'en1', 8, 'Home|5G', 61, 70, 200, 10);
        PRAGMA user_version = 3;
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func makePlan(
        id: UUID = UUID(),
        name: String
    ) -> UsagePlan {
        UsagePlan(
            id: id,
            name: name,
            currencyCode: "CNY",
            basePrice: 50,
            download: .unlimited,
            upload: .unlimited
        )
    }

    private func readUserVersion(at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func rowCount(in table: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM \(table);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func nullCount(in table: String, column: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NULL OR \(column) = '';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func physicalTotalsByNetwork(at url: URL) throws -> [String: UsageBytes] {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            SELECT wifi_network_id, SUM(downloaded_bytes), SUM(uploaded_bytes)
            FROM physical_samples
            GROUP BY wifi_network_id;
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: UsageBytes] = [:]
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw CocoaError(.fileReadUnknown)
            }
            guard let idBytes = sqlite3_column_text(statement, 0) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result[String(cString: idBytes)] = UsageBytes(
                downloadedBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                uploadedBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 2))
            )
        }
        return result
    }

    private func foreignKeyViolationCount(at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA foreign_key_check;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }

        var count = 0
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return count }
            guard stepResult == SQLITE_ROW else {
                throw CocoaError(.fileReadUnknown)
            }
            count += 1
        }
    }

    private func totalsByNetwork(
        in samples: [PhysicalUsageSample]
    ) -> [String: UsageBytes] {
        Dictionary(grouping: samples, by: { $0.network.networkID })
            .mapValues { networkSamples in
                networkSamples.reduce(.zero) { $0 + $1.bytes }
            }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
