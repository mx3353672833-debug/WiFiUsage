import Foundation
import SQLite3

public struct SQLiteUsageRepositoryError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

public struct LegacyDatabaseImportSummary: Equatable, Sendable {
    public let physicalSamples: Int
    public let applicationSamples: Int
    public let plans: Int

    public init(physicalSamples: Int, applicationSamples: Int, plans: Int) {
        self.physicalSamples = physicalSamples
        self.applicationSamples = applicationSamples
        self.plans = plans
    }
}

public actor SQLiteUsageRepository: UsageRepository {
    public static let schemaVersion = 4
    public static let busyTimeoutMilliseconds: Int32 = 5_000

    nonisolated(unsafe) private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let handle { sqlite3_close(handle) }
            throw SQLiteUsageRepositoryError(code: result, message: message)
        }
        database = handle

        do {
            guard sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds) == SQLITE_OK else {
                throw Self.databaseError(database: handle)
            }
            try Self.execute("PRAGMA foreign_keys = ON;", database: handle)
            try Self.execute("PRAGMA journal_mode = WAL;", database: handle)
            try Self.migrate(database: handle)
        } catch {
            // All stored properties are initialized, so Swift invokes deinit
            // for this failed initialization and closes the handle exactly once.
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public func save(physicalSample sample: PhysicalUsageSample) throws {
        try transaction {
            try upsertKnownWiFiNetwork(
                KnownWiFiNetwork(identity: sample.network, observedAt: sample.endedAt)
            )
            let statement = try prepare(Self.physicalInsertSQL)
            defer { sqlite3_finalize(statement) }
            try bindPhysicalSample(sample, to: statement)
            try step(statement)
        }
    }

    public func save(applicationSample sample: ApplicationUsageSample) throws {
        let statement = try prepare(Self.applicationInsertSQL)
        defer { sqlite3_finalize(statement) }
        try bindApplicationSample(sample, to: statement)
        try step(statement)
    }

    public func save(applicationSamples: [ApplicationUsageSample]) async throws {
        guard !applicationSamples.isEmpty else { return }
        try transaction {
            let statement = try prepare(Self.applicationInsertSQL)
            defer { sqlite3_finalize(statement) }
            for sample in applicationSamples {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindApplicationSample(sample, to: statement)
                try step(statement)
            }
        }
    }

    public func save(applicationBuckets: [ApplicationUsageBucket]) async throws {
        guard !applicationBuckets.isEmpty else { return }
        try transaction {
            let statement = try prepare(Self.applicationBucketUpsertSQL)
            defer { sqlite3_finalize(statement) }
            for bucket in applicationBuckets {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(bucket.applicationIdentifier, at: 1, to: statement)
                bind(bucket.carrier.rawValue, at: 2, to: statement)
                sqlite3_bind_double(statement, 3, bucket.bucketStart.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, bucket.endedAt.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 5, Int64(bitPattern: bucket.bytes.downloadedBytes))
                sqlite3_bind_int64(statement, 6, Int64(bitPattern: bucket.bytes.uploadedBytes))
                try step(statement)
            }
        }
    }

    public func save(wifiNetwork: KnownWiFiNetwork) throws {
        try upsertKnownWiFiNetwork(wifiNetwork)
    }

    public func save(plan: UsagePlan) throws {
        let statement = try prepare(
            """
            INSERT INTO usage_plans (id, payload) VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(plan.id.uuidString, at: 1, to: statement)
        bind(try String(decoding: encoder.encode(plan), as: UTF8.self), at: 2, to: statement)
        try step(statement)
    }

    public func setPlan(_ planID: UUID?, forWiFiNetwork networkID: String) throws {
        if let planID {
            let statement = try prepare(
                """
                INSERT INTO wifi_plan_assignments (network_id, plan_id, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(network_id) DO UPDATE SET
                    plan_id = excluded.plan_id,
                    updated_at = excluded.updated_at;
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(networkID, at: 1, to: statement)
            bind(planID.uuidString, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            try step(statement)
        } else {
            let statement = try prepare(
                "DELETE FROM wifi_plan_assignments WHERE network_id = ?;"
            )
            defer { sqlite3_finalize(statement) }
            bind(networkID, at: 1, to: statement)
            try step(statement)
        }
    }

    public func physicalSamples(in interval: DateInterval) throws -> [PhysicalUsageSample] {
        let sql = """
        SELECT id, interface_name, interface_index, ssid, started_at, ended_at,
               downloaded_bytes, uploaded_bytes
        FROM physical_samples
        WHERE ended_at > ? AND ended_at <= ?
        ORDER BY started_at ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)

        var result: [PhysicalUsageSample] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw databaseError(code: stepResult) }
            guard let id = UUID(uuidString: text(statement, column: 0)) else { continue }
            result.append(PhysicalUsageSample(
                id: id,
                network: WiFiNetworkIdentity(
                    interfaceName: text(statement, column: 1),
                    interfaceIndex: UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 2)),
                    ssid: optionalText(statement, column: 3)
                ),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                bytes: UsageBytes(
                    downloadedBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 6)),
                    uploadedBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 7))
                )
            ))
        }
        return result
    }

    public func applicationTotals(in interval: DateInterval) throws -> [ApplicationUsageTotal] {
        let sql = """
        SELECT application_identifier, carrier,
               SUM(downloaded_bytes), SUM(uploaded_bytes)
        FROM (
            SELECT application_identifier, carrier, downloaded_bytes, uploaded_bytes
            FROM application_samples
            WHERE ended_at > ? AND ended_at <= ?
            UNION ALL
            SELECT application_identifier, carrier, downloaded_bytes, uploaded_bytes
            FROM application_usage_buckets
            WHERE ended_at > ? AND ended_at <= ?
        )
        GROUP BY application_identifier, carrier
        ORDER BY application_identifier ASC, carrier ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, interval.end.timeIntervalSince1970)

        var totals: [ApplicationUsageTotal] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw databaseError(code: stepResult) }
            totals.append(ApplicationUsageTotal(
                applicationIdentifier: text(statement, column: 0),
                carrier: CarrierKind(rawValue: text(statement, column: 1)) ?? .unknown,
                bytes: UsageBytes(
                    downloadedBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                    uploadedBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 3))
                )
            ))
        }
        return totals
    }

    public func plans() throws -> [UsagePlan] {
        let statement = try prepare("SELECT payload FROM usage_plans ORDER BY id ASC;")
        defer { sqlite3_finalize(statement) }
        var result: [UsagePlan] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw databaseError(code: stepResult) }
            let payload = Data(text(statement, column: 0).utf8)
            result.append(try decoder.decode(UsagePlan.self, from: payload))
        }
        return result
    }

    public func knownWiFiNetworks() throws -> [KnownWiFiNetwork] {
        let statement = try prepare(
            """
            SELECT id, ssid, interface_name, first_seen_at, last_seen_at
            FROM wifi_networks
            ORDER BY last_seen_at DESC, id ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [KnownWiFiNetwork] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw databaseError(code: stepResult) }
            result.append(KnownWiFiNetwork(
                id: text(statement, column: 0),
                ssid: optionalText(statement, column: 1),
                interfaceName: text(statement, column: 2),
                firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return result
    }

    public func wifiPlanAssignments() throws -> [WiFiPlanAssignment] {
        let statement = try prepare(
            """
            SELECT network_id, plan_id, updated_at
            FROM wifi_plan_assignments
            ORDER BY network_id ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [WiFiPlanAssignment] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw databaseError(code: stepResult) }
            guard let planID = UUID(uuidString: text(statement, column: 1)) else { continue }
            result.append(WiFiPlanAssignment(
                networkID: text(statement, column: 0),
                planID: planID,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return result
    }

    public func deleteSamples(endingBefore date: Date) throws {
        try transaction {
            try delete(from: "physical_samples", endingBefore: date)
            try delete(from: "application_samples", endingBefore: date)
            try delete(from: "application_usage_buckets", endingBefore: date)
        }
    }

    /// Merges the former App Group database into the free local database.
    ///
    /// SQLite attaches the source directly so its WAL is read consistently.
    /// Existing primary keys are ignored and the source database is untouched.
    public func importLegacyDatabase(at sourceURL: URL) throws -> LegacyDatabaseImportSummary {
        let migrationKey = "legacy-app-group-v1"
        guard try !migrationCompleted(for: migrationKey) else {
            return LegacyDatabaseImportSummary(
                physicalSamples: 0,
                applicationSamples: 0,
                plans: 0
            )
        }

        let attach = try prepare("ATTACH DATABASE ? AS legacy;")
        bind(sourceURL.path, at: 1, to: attach)
        do {
            try step(attach)
            sqlite3_finalize(attach)
        } catch {
            sqlite3_finalize(attach)
            throw error
        }

        do {
            var physicalCount = 0
            var applicationCount = 0
            var planCount = 0
            try Self.execute("BEGIN IMMEDIATE;", database: database)

            if try Self.tableExists("physical_samples", schema: "legacy", database: database) {
                try Self.execute(
                    """
                    INSERT INTO main.wifi_networks
                    (id, ssid, interface_name, first_seen_at, last_seen_at)
                    SELECT
                        CASE
                            WHEN ssid IS NOT NULL AND length(ssid) > 0
                                THEN 'ssid:v1:' || lower(hex(ssid))
                            ELSE 'unidentified:v1:' || lower(hex(interface_name))
                        END,
                        NULLIF(ssid, ''),
                        MIN(interface_name),
                        MIN(started_at),
                        MAX(ended_at)
                    FROM legacy.physical_samples
                    WHERE true
                    GROUP BY
                        CASE
                            WHEN ssid IS NOT NULL AND length(ssid) > 0
                                THEN 'ssid:v1:' || lower(hex(ssid))
                            ELSE 'unidentified:v1:' || lower(hex(interface_name))
                        END
                    ON CONFLICT(id) DO UPDATE SET
                        ssid = COALESCE(excluded.ssid, wifi_networks.ssid),
                        interface_name = excluded.interface_name,
                        first_seen_at = MIN(wifi_networks.first_seen_at, excluded.first_seen_at),
                        last_seen_at = MAX(wifi_networks.last_seen_at, excluded.last_seen_at);
                    """,
                    database: database
                )
                try Self.execute(
                    """
                    INSERT OR IGNORE INTO main.physical_samples
                    (id, wifi_network_id, interface_name, interface_index, ssid, started_at, ended_at,
                     downloaded_bytes, uploaded_bytes)
                    SELECT
                        id,
                        CASE
                            WHEN ssid IS NOT NULL AND length(ssid) > 0
                                THEN 'ssid:v1:' || lower(hex(ssid))
                            ELSE 'unidentified:v1:' || lower(hex(interface_name))
                        END,
                        interface_name, interface_index, ssid, started_at, ended_at,
                        downloaded_bytes, uploaded_bytes
                    FROM legacy.physical_samples;
                    """,
                    database: database
                )
                physicalCount = Int(sqlite3_changes(database))
            }

            if try Self.tableExists("application_samples", schema: "legacy", database: database) {
                let hasCarrier = try Self.columnExists(
                    "application_samples",
                    column: "carrier",
                    schema: "legacy",
                    database: database
                )
                let carrierExpression = hasCarrier ? "COALESCE(carrier, 'unknown')" : "'unknown'"
                try Self.execute(
                    """
                    INSERT OR IGNORE INTO main.application_samples
                    (id, application_identifier, carrier, started_at, ended_at,
                     downloaded_bytes, uploaded_bytes)
                    SELECT id, application_identifier, \(carrierExpression), started_at, ended_at,
                           downloaded_bytes, uploaded_bytes
                    FROM legacy.application_samples;
                    """,
                    database: database
                )
                applicationCount = Int(sqlite3_changes(database))
            }

            if try Self.tableExists("usage_plans", schema: "legacy", database: database) {
                try Self.execute(
                    """
                    INSERT OR IGNORE INTO main.usage_plans (id, payload)
                    SELECT id, payload FROM legacy.usage_plans;
                    """,
                    database: database
                )
                planCount = Int(sqlite3_changes(database))
            }

            do {
                let marker = try prepare(
                    "INSERT OR REPLACE INTO migration_state (key, completed_at) VALUES (?, ?);"
                )
                defer { sqlite3_finalize(marker) }
                bind(migrationKey, at: 1, to: marker)
                sqlite3_bind_double(marker, 2, Date().timeIntervalSince1970)
                try step(marker)
            }

            try Self.execute("COMMIT;", database: database)
            try Self.execute("DETACH DATABASE legacy;", database: database)
            return LegacyDatabaseImportSummary(
                physicalSamples: physicalCount,
                applicationSamples: applicationCount,
                plans: planCount
            )
        } catch {
            try? Self.execute("ROLLBACK;", database: database)
            try? Self.execute("DETACH DATABASE legacy;", database: database)
            throw error
        }
    }

    private func bindPhysicalSample(_ sample: PhysicalUsageSample, to statement: OpaquePointer) throws {
        bind(sample.id.uuidString, at: 1, to: statement)
        bind(sample.network.networkID, at: 2, to: statement)
        bind(sample.network.interfaceName, at: 3, to: statement)
        sqlite3_bind_int64(statement, 4, Int64(sample.network.interfaceIndex))
        bind(sample.network.ssid, at: 5, to: statement)
        sqlite3_bind_double(statement, 6, sample.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, sample.endedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, Int64(bitPattern: sample.bytes.downloadedBytes))
        sqlite3_bind_int64(statement, 9, Int64(bitPattern: sample.bytes.uploadedBytes))
    }

    private func upsertKnownWiFiNetwork(_ network: KnownWiFiNetwork) throws {
        let statement = try prepare(
            """
            INSERT INTO wifi_networks
            (id, ssid, interface_name, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ssid = COALESCE(excluded.ssid, wifi_networks.ssid),
                interface_name = excluded.interface_name,
                first_seen_at = MIN(wifi_networks.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(wifi_networks.last_seen_at, excluded.last_seen_at);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(network.id, at: 1, to: statement)
        bind(network.ssid, at: 2, to: statement)
        bind(network.interfaceName, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, network.firstSeenAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, network.lastSeenAt.timeIntervalSince1970)
        try step(statement)
    }

    private func bindApplicationSample(_ sample: ApplicationUsageSample, to statement: OpaquePointer) throws {
        bind(sample.id.uuidString, at: 1, to: statement)
        bind(sample.applicationIdentifier, at: 2, to: statement)
        bind(sample.carrier.rawValue, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, sample.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, sample.endedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 6, Int64(bitPattern: sample.bytes.downloadedBytes))
        sqlite3_bind_int64(statement, 7, Int64(bitPattern: sample.bytes.uploadedBytes))
    }

    private func delete(from table: String, endingBefore date: Date) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE ended_at < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        try step(statement)
    }

    private func migrationCompleted(for key: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM migration_state WHERE key = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else { throw databaseError(code: result) }
        return false
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Self.execute("BEGIN IMMEDIATE;", database: database)
        do {
            let result = try body()
            try Self.execute("COMMIT;", database: database)
            return result
        } catch {
            try? Self.execute("ROLLBACK;", database: database)
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw databaseError(code: result) }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw databaseError(code: result) }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column: column)
    }

    private func databaseError(code: Int32) -> SQLiteUsageRepositoryError {
        SQLiteUsageRepositoryError(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static func migrate(database: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE;", database: database)
        do {
            var version = try userVersion(database: database)
            guard version <= schemaVersion else {
                throw SQLiteUsageRepositoryError(
                    code: SQLITE_MISMATCH,
                    message: "Database schema version \(version) is newer than supported version \(schemaVersion)"
                )
            }

            while version < schemaVersion {
                switch version {
                case 0:
                    try execute(schemaVersion1SQL, database: database)
                    version = 1
                    try execute("PRAGMA user_version = 1;", database: database)
                case 1:
                    // Older development builds could mark a partial database as v1.
                    // Re-running the idempotent base schema repairs any missing tables.
                    try execute(schemaVersion1SQL, database: database)
                    if try !Self.columnExists("application_samples", column: "carrier", database: database) {
                        try execute("ALTER TABLE application_samples ADD COLUMN carrier TEXT NOT NULL DEFAULT 'unknown';", database: database)
                    }
                    try execute("CREATE INDEX IF NOT EXISTS application_samples_application_carrier ON application_samples(application_identifier, carrier);", database: database)
                    version = 2
                    try execute("PRAGMA user_version = 2;", database: database)
                case 2:
                    try execute(schemaVersion1SQL, database: database)
                    if try !Self.columnExists("application_samples", column: "carrier", database: database) {
                        try execute("ALTER TABLE application_samples ADD COLUMN carrier TEXT NOT NULL DEFAULT 'unknown';", database: database)
                    }
                    try execute("CREATE INDEX IF NOT EXISTS application_samples_application_carrier ON application_samples(application_identifier, carrier);", database: database)
                    try execute(schemaVersion3SQL, database: database)
                    version = 3
                    try execute("PRAGMA user_version = 3;", database: database)
                case 3:
                    try execute(schemaVersion4TablesSQL, database: database)
                    if try !Self.columnExists(
                        "physical_samples",
                        column: "wifi_network_id",
                        database: database
                    ) {
                        try execute(
                            "ALTER TABLE physical_samples ADD COLUMN wifi_network_id TEXT REFERENCES wifi_networks(id);",
                            database: database
                        )
                    }
                    try execute(schemaVersion4BackfillSQL, database: database)
                    version = 4
                    try execute("PRAGMA user_version = 4;", database: database)
                default:
                    preconditionFailure("Unhandled schema version \(version)")
                }
            }
            try execute("COMMIT;", database: database)
        } catch {
            try? execute("ROLLBACK;", database: database)
            throw error
        }
    }

    private static func columnExists(
        _ table: String,
        column: String,
        schema: String = "main",
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "PRAGMA \(schema).table_info(\(table));"
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw databaseError(database: database, code: result)
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: value) == column { return true }
        }
        return false
    }

    private static func tableExists(
        _ table: String,
        schema: String,
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM \(schema).sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw databaseError(database: database, code: result)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_ROW { return true }
        guard stepResult == SQLITE_DONE else {
            throw databaseError(database: database, code: stepResult)
        }
        return false
    }
    private static func userVersion(database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw databaseError(database: database, code: prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw databaseError(database: database, code: stepResult)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteUsageRepositoryError(code: result, message: message)
        }
    }

    private static func databaseError(
        database: OpaquePointer,
        code: Int32? = nil
    ) -> SQLiteUsageRepositoryError {
        SQLiteUsageRepositoryError(
            code: code ?? sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    nonisolated(unsafe) private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private static let physicalInsertSQL = """
    INSERT OR REPLACE INTO physical_samples
    (id, wifi_network_id, interface_name, interface_index, ssid, started_at, ended_at,
     downloaded_bytes, uploaded_bytes)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    """

    private static let applicationInsertSQL = """
    INSERT OR IGNORE INTO application_samples
    (id, application_identifier, carrier, started_at, ended_at, downloaded_bytes, uploaded_bytes)
    VALUES (?, ?, ?, ?, ?, ?, ?);
    """

    private static let applicationBucketUpsertSQL = """
    INSERT INTO application_usage_buckets
    (application_identifier, carrier, bucket_start, ended_at, downloaded_bytes, uploaded_bytes)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(bucket_start, application_identifier, carrier) DO UPDATE SET
        ended_at = MAX(application_usage_buckets.ended_at, excluded.ended_at),
        downloaded_bytes = application_usage_buckets.downloaded_bytes + excluded.downloaded_bytes,
        uploaded_bytes = application_usage_buckets.uploaded_bytes + excluded.uploaded_bytes;
    """

    private static let schemaVersion1SQL = """
    CREATE TABLE IF NOT EXISTS physical_samples (
        id TEXT PRIMARY KEY NOT NULL,
        interface_name TEXT NOT NULL,
        interface_index INTEGER NOT NULL,
        ssid TEXT,
        started_at REAL NOT NULL,
        ended_at REAL NOT NULL,
        downloaded_bytes INTEGER NOT NULL,
        uploaded_bytes INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS physical_samples_interval
        ON physical_samples(started_at, ended_at);

    CREATE TABLE IF NOT EXISTS application_samples (
        id TEXT PRIMARY KEY NOT NULL,
        application_identifier TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL NOT NULL,
        downloaded_bytes INTEGER NOT NULL,
        uploaded_bytes INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS application_samples_interval
        ON application_samples(started_at, ended_at);
    CREATE INDEX IF NOT EXISTS application_samples_application
        ON application_samples(application_identifier);

    CREATE TABLE IF NOT EXISTS usage_plans (
        id TEXT PRIMARY KEY NOT NULL,
        payload TEXT NOT NULL
    );
    """

    private static let schemaVersion2SQL = """
    ALTER TABLE application_samples
        ADD COLUMN carrier TEXT NOT NULL DEFAULT 'unknown';
    CREATE INDEX IF NOT EXISTS application_samples_application_carrier
        ON application_samples(application_identifier, carrier);
    """

    private static let schemaVersion3SQL = """
    CREATE TABLE IF NOT EXISTS application_usage_buckets (
        application_identifier TEXT NOT NULL,
        carrier TEXT NOT NULL,
        bucket_start REAL NOT NULL,
        ended_at REAL NOT NULL,
        downloaded_bytes INTEGER NOT NULL,
        uploaded_bytes INTEGER NOT NULL,
        PRIMARY KEY (bucket_start, application_identifier, carrier)
    );
    CREATE INDEX IF NOT EXISTS application_usage_buckets_ended_at
        ON application_usage_buckets(ended_at);
    CREATE INDEX IF NOT EXISTS physical_samples_ended_at
        ON physical_samples(ended_at);
    CREATE INDEX IF NOT EXISTS application_samples_ended_at
        ON application_samples(ended_at);
    CREATE TABLE IF NOT EXISTS migration_state (
        key TEXT PRIMARY KEY NOT NULL,
        completed_at REAL NOT NULL
    );
    """

    private static let schemaVersion4TablesSQL = """
    CREATE TABLE IF NOT EXISTS wifi_networks (
        id TEXT PRIMARY KEY NOT NULL,
        ssid TEXT,
        interface_name TEXT NOT NULL,
        first_seen_at REAL NOT NULL,
        last_seen_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS wifi_plan_assignments (
        network_id TEXT PRIMARY KEY NOT NULL,
        plan_id TEXT NOT NULL,
        updated_at REAL NOT NULL,
        FOREIGN KEY(network_id) REFERENCES wifi_networks(id) ON DELETE CASCADE,
        FOREIGN KEY(plan_id) REFERENCES usage_plans(id) ON DELETE CASCADE
    );
    """

    private static let schemaVersion4BackfillSQL = """
    INSERT OR REPLACE INTO wifi_networks
    (id, ssid, interface_name, first_seen_at, last_seen_at)
    SELECT
        CASE
            WHEN ssid IS NOT NULL AND length(ssid) > 0
                THEN 'ssid:v1:' || lower(hex(ssid))
            ELSE 'unidentified:v1:' || lower(hex(interface_name))
        END,
        NULLIF(ssid, ''),
        MIN(interface_name),
        MIN(started_at),
        MAX(ended_at)
    FROM physical_samples
    GROUP BY
        CASE
            WHEN ssid IS NOT NULL AND length(ssid) > 0
                THEN 'ssid:v1:' || lower(hex(ssid))
            ELSE 'unidentified:v1:' || lower(hex(interface_name))
        END;

    UPDATE physical_samples
    SET wifi_network_id =
        CASE
            WHEN ssid IS NOT NULL AND length(ssid) > 0
                THEN 'ssid:v1:' || lower(hex(ssid))
            ELSE 'unidentified:v1:' || lower(hex(interface_name))
        END
    WHERE wifi_network_id IS NULL OR wifi_network_id = '';

    CREATE INDEX IF NOT EXISTS physical_samples_wifi_network_ended_at
        ON physical_samples(wifi_network_id, ended_at);
    """
}
