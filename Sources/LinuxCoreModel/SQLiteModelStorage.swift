import CoreModel
import CoreModelSQLite
import DynamicCoreModel
import RuntimeCoreModel
import SQLite

/// An open store: CoreModel-SQLite's `SQLiteDatabase`, with what
/// `HostModelStore` asks of a backend besides.
///
/// - **Batches are atomic**: one transaction, in which each insert and
///   delete makes a savepoint of its own.
/// - **What SQL can't say is evaluated here**: a predicate CoreModel-SQLite
///   can't translate is answered by CoreModel's own evaluator, over the
///   store's objects, so it answers as the in-memory store does.
/// - **SQLite's errors** are the contract's: a full disk is `outOfSpace`,
///   a file that isn't a database `corrupted`.
///
/// `HostModelStore` gives it one operation at a time, so a batch's
/// transaction has the connection to itself.
public final class SQLiteModelStorage: AtomicModelStorage {

    public let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    public func fetch(_ entity: EntityName, for id: ObjectID) async throws -> ModelData? {
        try await mapped { try await database.fetch(entity, for: id) }
    }

    public func fetch(_ fetchRequest: FetchRequest) async throws -> [ModelData] {
        try await mapped {
            do {
                return try await database.fetch(fetchRequest)
            } catch SQLiteDatabaseError.invalidPredicate {
                return try await evaluated(fetchRequest)
            }
        }
    }

    public func fetchID(_ fetchRequest: FetchRequest) async throws -> [ObjectID] {
        try await mapped {
            do {
                return try await database.fetchID(fetchRequest)
            } catch SQLiteDatabaseError.invalidPredicate {
                return try await evaluated(fetchRequest).map(\.id)
            }
        }
    }

    public func count(_ fetchRequest: FetchRequest) async throws -> UInt {
        try await mapped {
            do {
                return try await database.count(fetchRequest)
            } catch SQLiteDatabaseError.invalidPredicate {
                return UInt(try await evaluated(fetchRequest).count)
            }
        }
    }

    public func insert(_ value: ModelData) async throws {
        try await mapped { try await database.insert(value) }
    }

    public func insert(_ values: [ModelData]) async throws {
        try await mapped { try await database.insert(values) }
    }

    public func delete(_ entity: EntityName, for id: ObjectID) async throws {
        try await mapped { try await database.delete(entity, for: id) }
    }

    public func delete(_ entity: EntityName, for ids: [ObjectID]) async throws {
        try await mapped { try await database.delete(entity, for: ids) }
    }

    public func register(function: DatabaseFunction) async throws {
        try await mapped { try await database.register(function: function) }
    }

    public func perform(_ changes: ModelChanges) async throws {
        try await mapped {
            try await database.execute("BEGIN")
            do {
                for change in changes.changes {
                    switch change {
                    case .insert(let value):
                        try await database.insert(value)
                    case .delete(let entity, let id):
                        try await database.delete(entity, for: id)
                    }
                }
                try await database.execute("COMMIT")
            } catch {
                try? await database.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// The request answered by CoreModel's evaluator, over every object in
    /// the store, since its key paths may go through relationships.
    private func evaluated(_ request: FetchRequest) async throws -> [ModelData] {
        var objects = [ModelData]()
        for entity in await database.model.entities {
            objects += try await database.fetch(FetchRequest(entity: entity.id))
        }
        return request.evaluate(objects)
    }

    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.failure(error)
        }
    }

    /// The contract's error for one of SQLite's; any other error as it is.
    static func failure(_ error: any Error) -> any Error {
        guard let error = error as? SQLiteError else {
            return error
        }
        let message = error.message
        // The primary result code (https://sqlite.org/rescode.html).
        switch error.errorCode.rawValue & 0xff {
        case 13: // SQLITE_FULL
            return ModelStoreError(.outOfSpace, message: message)
        case 11, 26: // SQLITE_CORRUPT, SQLITE_NOTADB
            return ModelStoreError(.corrupted, message: message)
        case 8, 10, 14: // SQLITE_READONLY, SQLITE_IOERR, SQLITE_CANTOPEN
            // Also a storage whose file a migration replaced.
            return ModelStoreError(.unavailable, message: message)
        default:
            return ModelStoreError(.unknown, message: message)
        }
    }
}
