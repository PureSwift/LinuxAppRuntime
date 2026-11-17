import CoreModel
import CoreModelSQLite
import DynamicCoreModel
import Foundation
import RuntimeCoreModel
import SQLite

/// Model stores as SQLite databases in one directory: CoreModel-SQLite's
/// `SQLiteDatabase` behind `RuntimeCoreModel`'s `HostModelStore`
/// (`Plan.md` §9).
///
/// The store `name` is `<directory>/<name>.sqlite`. It keeps the model it
/// was made with in a table of its own, so the model and the objects
/// change together, and an open compares the two (AppRuntime's
/// `Persistence.md`, Migration):
///
/// - the same model opens the store as it is;
/// - one that `InMemoryModelStorageProvider.canMigrate(from:to:)` allows
///   is migrated by copying what both models have into a new database,
///   which then replaces the old one;
/// - any other fails with `migrationRequired`, or with `.reset` starts the
///   store again, empty.
///
/// A store open in several of the app's storages is one `SQLiteDatabase`,
/// since it caches what it reads and must be its file's only writer.
public actor SQLiteModelStorageProvider: ModelStorageProvider {

    public nonisolated let directory: String

    private var databases: [String: (model: Model, storage: SQLiteModelStorage)] = [:]

    public init(directory: String) {
        self.directory = directory
    }

    /// Where the store `name` is.
    public nonisolated func path(_ name: String) -> String {
        directory + "/" + name + ".sqlite"
    }

    public func open(_ name: String, model: Model, indexes: [EntityName: [[PropertyKey]]], migration: ModelMigration) async throws -> any ModelStorage {
        do {
            let storage = try await self.storage(name, model: model, migration: migration)
            try Self.updateIndexes(at: path(name), model: model, declared: indexes)
            return storage
        } catch {
            throw SQLiteModelStorage.failure(error)
        }
    }

    public func destroy(_ name: String) async throws {
        databases.removeValue(forKey: name)?.storage.close()
        let path = path(name)
        Self.remove(path)
        Self.remove(Self.migrating(path))
    }

    // MARK: Opening

    private func storage(_ name: String, model: Model, migration: ModelMigration) async throws -> SQLiteModelStorage {
        let model = Self.canonical(model)
        if let open = databases[name], open.model == model {
            return open.storage
        }
        let path = path(name)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError(.unavailable, message: "can't make \(directory): \(error)")
        }
        let stored = FileManager.default.fileExists(atPath: path) ? try Self.storedModel(at: path) : nil
        let storage: SQLiteModelStorage
        if let stored, stored == model {
            storage = try SQLiteModelStorage(database: SQLiteDatabase(path: path, model: model))
        } else if let stored, InMemoryModelStorageProvider.canMigrate(from: stored, to: model) {
            try await migrate(name, from: stored, to: model)
            storage = try SQLiteModelStorage(database: SQLiteDatabase(path: path, model: model))
        } else if stored != nil, migration == .fail {
            // A refused open changes nothing.
            throw ModelStoreError(.migrationRequired, message: "the store \(name) was made with another model")
        } else {
            // New, or emptied for a model it can't be migrated to.
            databases.removeValue(forKey: name)?.storage.close()
            Self.remove(path)
            storage = try SQLiteModelStorage(database: Self.create(at: path, model: model))
        }
        databases[name] = (model, storage)
        return storage
    }

    /// Copies what both models have into a new database, which replaces
    /// the store at `name`'s path once it's complete.
    private func migrate(_ name: String, from stored: Model, to model: Model) async throws {
        let path = path(name)
        let migrating = Self.migrating(path)
        Self.remove(migrating)
        do {
            // An open store is its file's writer; otherwise it's opened
            // only to be read.
            let old = try databases[name]?.storage.database ?? SQLiteDatabase(path: path, model: stored)
            try await Self.copy(from: old, to: migrating, model: model, stored: stored)
        } catch {
            Self.remove(migrating)
            throw error
        }
        // Storages still open on the old model lose their file, and fail
        // with `unavailable` from here on.
        databases.removeValue(forKey: name)?.storage.close()
        guard rename(migrating, path) == 0 else {
            let failure = ModelStoreError(.unavailable, message: "can't replace \(path): \(String(cString: strerror(errno)))")
            Self.remove(migrating)
            throw failure
        }
        Self.removeJournals(path)
    }

    /// Copies the objects of `old` that `model` has into a new database at
    /// `path`, with only the properties `model` has. The database is closed
    /// when this returns.
    private static func copy(from old: SQLiteDatabase, to path: String, model: Model, stored: Model) async throws {
        let new = try create(at: path, model: model)
        try await new.execute("BEGIN")
        do {
            for entity in model.entities where stored[entity.id] != nil {
                var objects = try await old.fetch(FetchRequest(entity: entity.id))
                for index in objects.indices {
                    objects[index].attributes = objects[index].attributes.filter { entity[attribute: $0.key] != nil }
                    objects[index].relationships = objects[index].relationships.filter { entity[relationship: $0.key] != nil }
                }
                try await new.insert(objects)
            }
            try await new.execute("COMMIT")
        } catch {
            try? await new.execute("ROLLBACK")
            throw error
        }
    }

    /// A new database at `path` for `model`, which it keeps.
    private static func create(at path: String, model: Model) throws -> SQLiteDatabase {
        let connection = try Connection(path: path)
        let json = String(decoding: try JSONEncoder.sorted.encode(model), as: UTF8.self)
        try connection.transaction {
            try connection.run("CREATE TABLE IF NOT EXISTS \(modelTable.quoted) (\("model".quoted) TEXT NOT NULL)")
            try connection.run("DELETE FROM \(modelTable.quoted)")
            try connection.run("INSERT INTO \(modelTable.quoted) (\("model".quoted)) VALUES (?)", [.text(json)])
        }
        return try SQLiteDatabase(connection: connection, model: model)
    }

    /// The model the store at `path` was made with; `nil` for a file that
    /// has none, such as one left before its model was written.
    static func storedModel(at path: String) throws -> Model? {
        let connection = try Connection(path: path)
        let tables = try connection.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(modelTable)])
        guard let count = tables?.integer, count > 0 else {
            return nil
        }
        guard let json = try connection.scalar("SELECT \("model".quoted) FROM \(modelTable.quoted) LIMIT 1")?.string else {
            return nil
        }
        do {
            return canonical(try JSONDecoder().decode(Model.self, from: Data(json.utf8)))
        } catch {
            throw ModelStoreError(.corrupted, message: "the store's model doesn't decode: \(error)")
        }
    }

    // MARK: Indexes

    /// The table the store's model is kept in. Not an entity's: CoreModel's
    /// entity names don't have a `.`.
    static let modelTable = "appruntime.model"

    /// The prefix of the indexes this keeps.
    static let indexPrefix = "appruntime.index."

    /// Makes the indexes the app declared, and one on each to-one
    /// relationship's column, which a to-many is read through; drops those
    /// it no longer wants.
    static func updateIndexes(at path: String, model: Model, declared: [EntityName: [[PropertyKey]]]) throws {
        var wanted: [String: String] = [:]
        for entity in model.entities {
            var lists = declared[entity.id] ?? []
            lists += entity.relationships.filter { $0.type == .toOne }.map { [$0.id] }
            for keys in lists {
                // Only columns can be indexed: attributes and to-ones.
                let columns = keys.allSatisfy { key in
                    entity[attribute: key] != nil || entity[relationship: key]?.type == .toOne
                }
                guard columns, !keys.isEmpty else { continue }
                let name = indexPrefix + entity.id.rawValue + "." + keys.map(\.rawValue).joined(separator: ",")
                wanted[name] = "CREATE INDEX IF NOT EXISTS \(name.quoted) ON \(entity.id.rawValue.quoted) (\(keys.map(\.rawValue.quoted).joined(separator: ", ")))"
            }
        }
        let connection = try Connection(path: path)
        let list = try connection.scalar(
            "SELECT group_concat(name, char(10)) FROM sqlite_master WHERE type = 'index' AND substr(name, 1, ?) = ?",
            [.integer(Int64(indexPrefix.utf8.count)), .text(indexPrefix)])
        let existing = Set((list?.string ?? "").split(separator: "\n").map(String.init))
        try connection.transaction {
            for name in existing where wanted[name] == nil {
                try connection.run("DROP INDEX IF EXISTS \(name.quoted)")
            }
            for (name, sql) in wanted where !existing.contains(name) {
                try connection.run(sql)
            }
        }
    }

    // MARK: Files

    static func migrating(_ path: String) -> String {
        path + ".migrating"
    }

    /// Removes a database and whatever SQLite keeps beside it.
    static func remove(_ path: String) {
        unlink(path)
        removeJournals(path)
    }

    static func removeJournals(_ path: String) {
        for suffix in ["-journal", "-wal", "-shm"] {
            unlink(path + suffix)
        }
    }

    /// A model with its entities and properties in one order, so two that
    /// say the same thing are equal.
    static func canonical(_ model: Model) -> Model {
        Model(entities: model.entities
            .map { entity in
                EntityDescription(
                    id: entity.id,
                    attributes: entity.attributes.sorted { $0.id.rawValue < $1.id.rawValue },
                    relationships: entity.relationships.sorted { $0.id.rawValue < $1.id.rawValue }
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue })
    }
}

extension String {

    /// A quoted SQL identifier.
    var quoted: String {
        "\"" + replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension JSONEncoder {

    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
