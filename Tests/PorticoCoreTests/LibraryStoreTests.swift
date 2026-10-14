import Foundation
import XCTest
@testable import PorticoCore

final class LibraryStoreTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PorticoStoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL { try FileManager.default.removeItem(at: temporaryURL) }
    }

    private func makeStore() throws -> LibraryStore {
        try LibraryStore(rootURL: temporaryURL.appendingPathComponent("Store", isDirectory: true))
    }

    private func sampleLibrary() -> Library {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bottle = Bottle(name: "Divinity", createdAt: date, status: .ready, enginePath: "/opt/wine/bin/wine")
        let game = Game(name: "Divinity: Original Sin 2", bottleID: bottle.id,
                        executablePath: "/Games/Divinity/bin/EoCApp.exe", arguments: ["--skip-launcher"],
                        workingDirectory: "/Games/Divinity/bin", addedAt: date,
                        lastPlayedAt: date, isFavorite: true)
        return Library(bottles: [bottle], games: [game], settings: AppSettings(enginePath: bottle.enginePath))
    }

    func testNewStoreLoadsEmptyLibrary() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.load(), Library())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.libraryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent("Bottles").path))
    }

    func testRoundTripPreservesLibraryAndWritesISO8601Dates() throws {
        let store = try makeStore()
        let library = sampleLibrary()
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        let json = try String(contentsOf: store.libraryURL, encoding: .utf8)
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"))
    }

    func testMultipleGameProfilesRetainSettingsAndIdentityAfterEditingAndReloading() throws {
        let store = try makeStore()
        var library = sampleLibrary()
        let original = library.games[0]
        let date = Date(timeIntervalSince1970: 1_700_100_000)
        let secondBottle = Bottle(name: "Jagged Alliance 2", createdAt: date, status: .ready,
                                  enginePath: "/opt/other-wine/bin/wine")
        let secondGame = Game(name: "Jagged Alliance 2", bottleID: secondBottle.id,
                              executablePath: "/Games/JA2/JA2.exe", arguments: [], addedAt: date)
        library.bottles.append(secondBottle)
        library.games.append(secondGame)
        try store.save(library)

        var edited = try store.load()
        edited.games[0].name = "Divinity — custom profile"
        edited.games[0].executablePath = "/Games/Divinity/DefEd/bin/EoCApp.exe"
        edited.games[0].arguments = ["", " two words ", "--custom=literal"]
        edited.games[0].workingDirectory = "/Games/Divinity/DefEd"
        try store.save(edited)
        let restored = try store.load()

        XCTAssertEqual(restored, edited)
        XCTAssertEqual(restored.games[0].id, original.id)
        XCTAssertEqual(restored.games[0].bottleID, original.bottleID)
        XCTAssertEqual(restored.games[0].addedAt, original.addedAt)
        XCTAssertEqual(restored.games[0].lastPlayedAt, original.lastPlayedAt)
        XCTAssertEqual(restored.games[0].isFavorite, original.isFavorite)
        XCTAssertEqual(restored.games[1], secondGame)
        XCTAssertEqual(restored.bottles[1], secondBottle)
    }

    func testCorruptFileIsReportedAndPreserved() throws {
        let store = try makeStore()
        let corrupt = Data("{broken JSON".utf8)
        try corrupt.write(to: store.libraryURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), corrupt)
    }

    func testSteamMetadataRoundTripsAndOldGamesStillDecode() throws {
        let store = try makeStore()
        var library = sampleLibrary()
        try store.save(library)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.libraryURL)) as? [String: Any])
        var games = try XCTUnwrap(object["games"] as? [[String: Any]])
        games[0].removeValue(forKey: "steamAppID")
        object["games"] = games
        try JSONSerialization.data(withJSONObject: object).write(to: store.libraryURL)
        XCTAssertEqual(try store.load(), library)
        XCTAssertNil(try store.load().games[0].steamAppID)
        library.games[0].steamAppID = "435150"
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        let saved = try Data(contentsOf: store.libraryURL)
        library.games[0].steamAppID = "435150/extra"
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), saved)
    }

    func testInterruptedCreationRecoversOnlyInMemory() throws {
        let store = try makeStore()
        var library = sampleLibrary()
        library.bottles[0].status = .creating
        try store.save(library)
        let original = try Data(contentsOf: store.libraryURL)
        XCTAssertEqual(try store.load().bottles[0].status, .failed)
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), original)
    }

    func testUnsupportedSchemaIsReportedWithoutReplacingFile() throws {
        let store = try makeStore()
        var library = sampleLibrary()
        library.schemaVersion = 2
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)
        try data.write(to: store.libraryURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("2"))
        }
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), data)
    }

    func testFutureSchemaIsRecognizedBeforeDecodingChangedPayload() throws {
        let store = try makeStore()
        try Data("{\"schemaVersion\": 3, \"differentFutureStructure\": true}".utf8).write(to: store.libraryURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error.localizedDescription, L10n.text("Версія бібліотеки \(3) не підтримується. Ця версія Portico підтримує формат 1."))
        }
    }

    func testInvalidSavePreservesPreviouslySavedLibrary() throws {
        let store = try makeStore()
        let original = sampleLibrary()
        try store.save(original)
        let data = try Data(contentsOf: store.libraryURL)
        var invalid = original
        invalid.games[0].bottleID = UUID()
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), data)
        XCTAssertEqual(try store.load(), original)
    }

    func testDuplicateIDsAndInvalidNamesAreRejected() throws {
        let store = try makeStore()
        var library = sampleLibrary()
        library.bottles.append(library.bottles[0])
        XCTAssertThrowsError(try store.save(library))
        library = sampleLibrary()
        library.games.append(library.games[0])
        XCTAssertThrowsError(try store.save(library))
        for name in [" \n ", "Bad\u{0000}name", String(repeating: "a", count: 201)] {
            library = sampleLibrary()
            library.bottles[0].name = name
            XCTAssertThrowsError(try store.save(library))
        }
    }

    func testInvalidUUIDAndDanglingReferenceOnDiskAreRejected() throws {
        let store = try makeStore()
        try store.save(sampleLibrary())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.libraryURL)) as? [String: Any])
        var bottles = try XCTUnwrap(object["bottles"] as? [[String: Any]])
        bottles[0]["id"] = "../../outside"
        object["bottles"] = bottles
        try JSONSerialization.data(withJSONObject: object).write(to: store.libraryURL)
        XCTAssertThrowsError(try store.load())
        var library = sampleLibrary()
        library.games[0].bottleID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: store.libraryURL)
        XCTAssertThrowsError(try store.load())
    }

    func testNamesCannotChangeManagedPathsOrDeletionTarget() throws {
        let store = try makeStore()
        var bottle = sampleLibrary().bottles[0]
        let prefix = store.prefixURL(for: bottle)
        bottle.name = "../../outside"
        XCTAssertEqual(store.prefixURL(for: bottle), prefix)
        XCTAssertEqual(prefix.deletingLastPathComponent(), store.rootURL.appendingPathComponent("Bottles", isDirectory: true))
        XCTAssertEqual(store.logURL(for: bottle).lastPathComponent, bottle.id.uuidString + ".log")
        let outside = temporaryURL.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("save data".utf8).write(to: prefix.appendingPathComponent("save.dat"))
        try Data("log".utf8).write(to: store.logURL(for: bottle))
        try store.removeBottleData(bottle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.logURL(for: bottle).path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testSymlinkedManagedFolderCannotRedirectDeletion() throws {
        let store = try makeStore()
        let bottle = sampleLibrary().bottles[0]
        let outside = temporaryURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let bottles = store.rootURL.appendingPathComponent("Bottles")
        try FileManager.default.removeItem(at: bottles)
        try FileManager.default.createSymbolicLink(at: bottles, withDestinationURL: outside)
        XCTAssertThrowsError(try store.removeBottleData(bottle))
        XCTAssertThrowsError(try store.save(Library()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSymlinkedLibraryCannotOverwriteExternalFile() throws {
        let store = try makeStore()
        let outside = temporaryURL.appendingPathComponent("external.json")
        let marker = Data("external".utf8)
        try marker.write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.libraryURL, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Library()))
        XCTAssertEqual(try Data(contentsOf: outside), marker)
    }

    func testSuccessfulReplacementLeavesNoTemporaryFiles() throws {
        let store = try makeStore()
        try store.save(sampleLibrary())
        try store.save(Library())
        XCTAssertEqual(try store.load(), Library())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)),
                       Set(["Bottles", "Logs", "library.json"]))
    }
}
