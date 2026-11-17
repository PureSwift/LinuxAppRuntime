import CoreModel
import CoreModelSQLite
import DynamicCoreModel
import Foundation
import RuntimeCoreModel
import SQLite
import Testing
@testable import LinuxCoreModel

// MARK: The model

/// Written by hand, as a guest writes them: CoreModel's macros are off
/// under Embedded Swift.
struct Person: Entity, Equatable {

    static var entityName: EntityName { "Person" }

    static var attributes: [CodingKeys: AttributeType] {
        [
            .name: .string, .age: .int32, .rank: .int16, .visits: .int64, .ratio: .float, .score: .double,
            .isMember: .bool, .joined: .date, .token: .uuid, .homepage: .url, .balance: .decimal, .photo: .data,
        ]
    }

    static var relationships: [CodingKeys: Relationship] {
        [.team: Relationship(id: "team", type: .toOne, destinationEntity: "Team", inverseRelationship: "members")]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, age, rank, visits, ratio, score, isMember, joined, token, homepage, balance, photo, team
    }

    let id: String
    var name: String
    var age: Int32
    var rank: Int16 = 0
    var visits: Int64 = 0
    var ratio: Float = 0
    var score: Double = 0
    var isMember = false
    var joined: Date?
    var token: UUID?
    var homepage: URL?
    var balance: Decimal?
    var photo: Data?
    var team: String?

    init(id: String, name: String, age: Int32, score: Double = 0, isMember: Bool = false, team: String? = nil) {
        self.id = id
        self.name = name
        self.age = age
        self.score = score
        self.isMember = isMember
        self.team = team
    }

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        name = try model.decode(String.self, forKey: CodingKeys.name)
        age = try model.decode(Int32.self, forKey: CodingKeys.age)
        rank = try model.decode(Int16.self, forKey: CodingKeys.rank)
        visits = try model.decode(Int64.self, forKey: CodingKeys.visits)
        ratio = try model.decode(Float.self, forKey: CodingKeys.ratio)
        score = try model.decode(Double.self, forKey: CodingKeys.score)
        isMember = try model.decode(Bool.self, forKey: CodingKeys.isMember)
        joined = try model.decode(Date?.self, forKey: CodingKeys.joined)
        token = try model.decode(UUID?.self, forKey: CodingKeys.token)
        homepage = try model.decode(URL?.self, forKey: CodingKeys.homepage)
        balance = try model.decode(Decimal?.self, forKey: CodingKeys.balance)
        photo = try model.decode(Data?.self, forKey: CodingKeys.photo)
        team = try model.decodeRelationship(String?.self, forKey: CodingKeys.team)
    }

    func encode() -> ModelData {
        var data = ModelData(entity: Self.entityName, id: ObjectID(rawValue: id))
        data.encode(name, forKey: CodingKeys.name)
        data.encode(age, forKey: CodingKeys.age)
        data.encode(rank, forKey: CodingKeys.rank)
        data.encode(visits, forKey: CodingKeys.visits)
        data.encode(ratio, forKey: CodingKeys.ratio)
        data.encode(score, forKey: CodingKeys.score)
        data.encode(isMember, forKey: CodingKeys.isMember)
        data.encode(joined, forKey: CodingKeys.joined)
        data.encode(token, forKey: CodingKeys.token)
        data.encode(homepage, forKey: CodingKeys.homepage)
        data.encode(balance, forKey: CodingKeys.balance)
        data.encode(photo, forKey: CodingKeys.photo)
        data.encodeRelationship(team, forKey: CodingKeys.team)
        return data
    }
}

struct Team: Entity, Equatable {

    static var entityName: EntityName { "Team" }

    static var attributes: [CodingKeys: AttributeType] { [.name: .string] }

    static var relationships: [CodingKeys: Relationship] {
        [.members: Relationship(id: "members", type: .toMany, destinationEntity: "Person", inverseRelationship: "team")]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, members
    }

    let id: String
    var name: String
    var members: [String] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from model: ModelData) throws(ModelDataDecodingError) {
        id = model.id.rawValue
        name = try model.decode(String.self, forKey: CodingKeys.name)
        members = try model.decodeRelationship([String].self, forKey: CodingKeys.members).sorted()
    }

    func encode() -> ModelData {
        var data = ModelData(entity: Self.entityName, id: ObjectID(rawValue: id))
        data.encode(name, forKey: CodingKeys.name)
        return data
    }
}

/// The SQLite stores, each test in a directory of its own, against
/// CoreModel's in-memory store as the reference for what a request
/// returns.
@Suite struct LinuxCoreModelTests {

    static let model = Model(entities: [
        EntityDescription(entity: Person.self),
        EntityDescription(entity: Team.self),
        EntityDescription(id: "Note", attributes: [Attribute(id: "text", type: .string)], relationships: []),
    ])

    static let people: [Person] = {
        var ada = Person(id: "ada", name: "Ada", age: 36, score: 9.5, isMember: true, team: "engine")
        ada.rank = -3
        ada.visits = 1 << 40
        ada.ratio = 0.25
        ada.joined = Date(timeIntervalSince1970: 1_700_000_000.5)
        ada.token = UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")
        ada.homepage = URL(string: "https://example.com/ada?x=1")
        ada.balance = Decimal(string: "1234.5678")
        ada.photo = Data([0, 1, 2, 255])
        return [
            ada,
            Person(id: "grace", name: "Grace", age: 45, score: 8, isMember: true, team: "engine"),
            Person(id: "alan", name: "alan", age: 41, score: 7.25, team: "theory"),
            Person(id: "edsger", name: "Édsger", age: 17, score: 0),
            Person(id: "linus", name: "Linus", age: 17, score: 3, isMember: true, team: "theory"),
        ]
    }()

    static var objects: [ModelData] {
        [Team(id: "engine", name: "Engine").encode(), Team(id: "theory", name: "Theory").encode()] + people.map { $0.encode() }
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linux-core-model-\(UUID())").path

    func provider() -> SQLiteModelStorageProvider {
        SQLiteModelStorageProvider(directory: directory)
    }

    func open(_ provider: SQLiteModelStorageProvider, _ model: Model = LinuxCoreModelTests.model, indexes: [EntityName: [[PropertyKey]]] = [:],
              migration: ModelMigration = .fail) async throws -> SQLiteModelStorage {
        try #require(try await provider.open("library", model: model, indexes: indexes, migration: migration) as? SQLiteModelStorage)
    }

    /// What a failing call failed with; `nil` when it didn't.
    func failure(_ body: () async throws -> Void) async -> ModelStoreError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? ModelStoreError)?.code
        }
    }

    // MARK: Where

    @Test func storesAreBesideTheAppsDocuments() throws {
        #expect(try LinuxModelStore.directory(identifier: "org.example.App", environment: ["HOME": "/home/ada"])
                == "/home/ada/.local/share/org.example.App/Stores")
        #expect(try LinuxModelStore.directory(identifier: "org.example.App", environment: ["HOME": "/home/ada", "XDG_DATA_HOME": "/data"])
                == "/data/org.example.App/Stores")
        #expect(try LinuxModelStore.directory(identifier: "org.example.App", environment: ["LINUXAPPRUNTIME_CONTAINER": "/roms/ports/app/conf"])
                == "/roms/ports/app/conf/Stores")
        #expect(throws: (any Error).self) {
            try LinuxModelStore.directory(identifier: "../x", environment: ["HOME": "/home/ada"])
        }
        #expect(provider().path("library") == directory + "/library.sqlite")
    }

    // MARK: What a request returns

    @Test func requestsAnswerAsTheReference() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = try await open(provider())
        let reference = InMemoryModelStorage(model: Self.model)
        try await store.insert(Self.objects)
        try await reference.insert(Self.objects)

        typealias Predicate = FetchRequest.Predicate
        let age: Predicate.Expression = .keyPath("age")
        let predicates: [Predicate?] = [
            nil,
            .value(true),
            .value(false),
            Person.CodingKeys.age >= Int32(18),
            Person.CodingKeys.age < Int32(18),
            Person.CodingKeys.age == Int32(17),
            Person.CodingKeys.age != Int32(17),
            Person.CodingKeys.score > 7.5,
            Person.CodingKeys.isMember == true,
            Person.CodingKeys.name == "alan",
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("a")), type: .beginsWith)),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("a")), type: .beginsWith, options: [.caseInsensitive])),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("N")), type: .endsWith, options: [.caseInsensitive])),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("ra")), type: .contains)),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("*a*")), type: .like)),
            .comparison(.init(left: .keyPath("name"), right: .attribute(.string("Ada Lovelace")), type: .in)),
            .comparison(.init(left: .keyPath("joined"), right: .attribute(.null), type: .equalTo)),
            .comparison(.init(left: .keyPath("joined"), right: .attribute(.date(Date(timeIntervalSince1970: 1_600_000_000))), type: .greaterThan)),
            .comparison(.init(left: .keyPath("token"), right: .attribute(.uuid(UUID(uuidString: "9E3C1A52-0C1B-4F0E-9D4B-6A1F2C3D4E5F")!)), type: .equalTo)),
            .comparison(.init(left: .keyPath("photo"), right: .attribute(.data(Data([0, 1, 2, 255]))), type: .equalTo)),
            .comparison(.init(left: .keyPath("visits"), right: .attribute(.int64(1 << 40)), type: .equalTo)),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.toOne("engine")), type: .equalTo)),
            .comparison(.init(left: .keyPath("team"), right: .relationship(.null), type: .equalTo)),
            .comparison(.init(left: .keyPath("team.name"), right: .attribute(.string("Theory")), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .add, left: age, right: .attribute(.int32(4)))), right: .attribute(.int32(45)), type: .equalTo)),
            .comparison(.init(left: .arithmetic(.init(function: .multiply, left: .keyPath("score"), right: .attribute(.double(2)))), right: .attribute(.double(15)), type: .greaterThan)),
            .compound(.and([Person.CodingKeys.age >= Int32(18), Person.CodingKeys.isMember == true])),
            .compound(.or([Person.CodingKeys.age < Int32(18), Person.CodingKeys.name == "Ada"])),
            .compound(.not(Person.CodingKeys.isMember == true)),
            .compound(.and([])),
            .compound(.or([])),
        ]
        let sorts: [[FetchRequest.SortDescriptor]] = [
            [],
            [.init(property: "name")],
            [.init(property: "age"), .init(property: "score", ascending: false)],
            [.init(property: "joined", ascending: false)],
        ]
        for predicate in predicates {
            for sort in sorts {
                for (limit, offset) in [(0, 0), (2, 0), (2, 1), (0, 4)] {
                    let request = FetchRequest(entity: "Person", sortDescriptors: sort, predicate: predicate, fetchLimit: limit, fetchOffset: offset)
                    let expected = try await reference.fetch(request)
                    let found = try await store.fetch(request)
                    #expect(found.map(\.id) == expected.map(\.id), "\(String(describing: predicate)) \(sort.map { "\($0.term) \($0.ascending)" }) \(limit) \(offset): expected \(expected.map(\.id.rawValue))")
                    #expect(try await store.fetchID(request) == expected.map(\.id))
                    #expect(try await store.count(request) == UInt(expected.count))
                }
            }
        }
        // Something matched: neither answers nothing to everything.
        #expect(try await store.count(FetchRequest(entity: "Person", predicate: Person.CodingKeys.age >= Int32(18))) == 3)

        // Through to-many relationships.
        let members: FetchRequest.Predicate = .comparison(.init(left: .keyPath("members"), right: .relationship(.toOne("linus")), type: .contains))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: members)) == ["theory"])
        let anyMember: FetchRequest.Predicate = .comparison(.init(left: .keyPath("members.age"), right: .attribute(.int32(40)), type: .greaterThan, modifier: .any))
        #expect(try await store.fetchID(FetchRequest(entity: "Team", predicate: anyMember))
                == (try await reference.fetchID(FetchRequest(entity: "Team", predicate: anyMember))))
    }

    @Test func everyValueComesBackAsItWent() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = try await open(provider())
        try await store.insert(Self.objects)
        for person in Self.people {
            let found = try #require(try await store.fetch(Person.entityName, for: ObjectID(rawValue: person.id)))
            #expect(try Person(from: found) == person)
        }
        let engine = try #require(try await store.fetch("Team", for: "engine"))
        #expect(try Team(from: engine).members == ["ada", "grace"])
    }

    // MARK: Writes

    @Test func aBatchIsAppliedWholeOrNotAtAll() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = try await open(provider())
        try await store.insert(Self.objects)

        var changes = ModelChanges()
        changes.insert(Person(id: "barbara", name: "Barbara", age: 30).encode())
        changes.delete(Person.entityName, for: "ada")
        // An insert merges: the properties a record has, and the rest left.
        var renamed = ModelData(entity: Person.entityName, id: "grace")
        renamed.encode("Grace Hopper", forKey: Person.CodingKeys.name)
        changes.insert(renamed)
        try await store.perform(changes)
        #expect(Set(try await store.fetchID(FetchRequest(entity: "Person"))) == ["alan", "barbara", "edsger", "grace", "linus"])
        let grace = try Person(from: try #require(try await store.fetch(Person.entityName, for: "grace")))
        #expect(grace.name == "Grace Hopper" && grace.age == 45 && grace.team == "engine")
        // The other side of a deleted object's relationship follows.
        #expect(try Team(from: try #require(try await store.fetch("Team", for: "engine"))).members == ["grace"])

        // The last change can't be applied: none of them is.
        var failing = ModelChanges()
        failing.delete(Person.entityName, for: "linus")
        failing.insert(Note(id: "n1", text: "kept?"))
        failing.insert(ModelData(entity: "Nothing", id: "x"))
        await #expect(throws: (any Error).self) { try await store.perform(failing) }
        #expect(try await store.fetch(Person.entityName, for: "linus") != nil)
        #expect(try await store.count(FetchRequest(entity: "Note")) == 0)
        // And the store goes on.
        try await store.perform(ModelChanges())
        try await store.insert(Note(id: "n2", text: "after"))
        #expect(try await store.count(FetchRequest(entity: "Note")) == 1)
    }

    // MARK: Opening

    @Test func aStoreKeepsItsObjectsBetweenOpenings() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = provider()
        let store = try await open(first)
        #expect(try await open(first) === store)
        try await store.insert(Self.objects)

        // Another launch.
        let reopened = try await open(provider())
        #expect(reopened !== store)
        #expect(try await reopened.count(FetchRequest(entity: "Person")) == 5)
        #expect(try await reopened.fetchID(FetchRequest(entity: "Person", predicate: Person.CodingKeys.isMember == true)) == ["ada", "grace", "linus"])

        // Destroyed, it's empty.
        try await first.destroy("library")
        #expect(!FileManager.default.fileExists(atPath: first.path("library")))
        #expect(try await open(provider()).count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func aChangedModelMigratesOrIsRefused() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = try await open(provider())
        try await store.insert(Self.objects)
        try await store.insert(Note(id: "n1", text: "a note"))

        // Notes are gone; a person has an email and no score; there are tags.
        func entity(_ id: EntityName, _ edit: (inout EntityDescription) -> Void) -> EntityDescription {
            var entity = Self.model[id]!
            edit(&entity)
            return entity
        }
        let person = entity("Person") { person in
            person.attributes.removeAll { $0.id == "score" }
            person.attributes.append(Attribute(id: "email", type: .string))
        }
        let migrated = Model(entities: [
            person, Self.model["Team"]!,
            EntityDescription(id: "Tag", attributes: [Attribute(id: "label", type: .string)], relationships: []),
        ])
        let next = provider()
        let opened = try await open(next, migrated)
        #expect(try await opened.count(FetchRequest(entity: "Person")) == 5)
        let ada = try #require(try await opened.fetch(Person.entityName, for: "ada"))
        #expect(ada.attributes["name"] == .string("Ada"))
        #expect(ada.attributes["score"] == nil)
        #expect(ada.attributes["email"] == .null)
        #expect(ada.relationships["team"] == .toOne("engine"))
        #expect(try Team(from: try #require(try await opened.fetch("Team", for: "theory"))).members == ["alan", "linus"])
        try await opened.insert(ModelData(entity: "Tag", id: "t", attributes: ["label": .string("new")]))
        // A storage still open on the old model has lost its file to the
        // new one: it fails, and says so.
        #expect(await failure { _ = try await store.count(FetchRequest(entity: "Note")) } == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: next.path("library") + ".migrating"))

        // A name that's now a number can't be migrated: refused, and the
        // store is as it was.
        let renumbered = Model(entities: [
            entity("Person") { person in
                person.attributes = person.attributes.map { $0.id == "name" ? Attribute(id: "name", type: .int64) : $0 }
            },
            Self.model["Team"]!,
        ])
        #expect(await failure { _ = try await open(provider(), renumbered) } == .migrationRequired)
        #expect(try await open(provider(), migrated).count(FetchRequest(entity: "Tag")) == 1)

        // Or emptied, when the app says so.
        let reset = try await open(provider(), renumbered, migration: .reset)
        #expect(try await reset.count(FetchRequest(entity: "Person")) == 0)
        #expect(try await open(provider(), renumbered).count(FetchRequest(entity: "Person")) == 0)
    }

    @Test func indexesFollowTheApp() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        func indexes(_ provider: SQLiteModelStorageProvider) throws -> [String] {
            let connection = try Connection(path: provider.path("library"))
            let list = try connection.scalar("SELECT group_concat(name, char(10)) FROM sqlite_master WHERE type = 'index' AND name LIKE 'appruntime.index.%'")
            return (list?.string ?? "").split(separator: "\n").map(String.init).sorted()
        }
        let first = provider()
        _ = try await open(first, indexes: ["Person": [["name"], ["age", "score"]]])
        #expect(try indexes(first) == ["appruntime.index.Person.age,score", "appruntime.index.Person.name", "appruntime.index.Person.team"])
        // One dropped; the relationship's stays.
        let second = provider()
        _ = try await open(second, indexes: ["Person": [["age", "score"]]])
        #expect(try indexes(second) == ["appruntime.index.Person.age,score", "appruntime.index.Person.team"])
    }

    @Test func aFileThatIsNotAStoreIsCorrupted() async throws {
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let provider = provider()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: provider.path("library")))
        #expect(await failure { _ = try await open(provider) } == .corrupted)
    }

    @Test func withoutADirectoryThereIsNoStore() async throws {
        let provider = SQLiteModelStorageProvider(directory: "/proc/no-stores-here")
        #expect(await failure { _ = try await open(provider) } == .unavailable)
    }
}

func Note(id: ObjectID, text: String) -> ModelData {
    ModelData(entity: "Note", id: id, attributes: ["text": .string(text)])
}
