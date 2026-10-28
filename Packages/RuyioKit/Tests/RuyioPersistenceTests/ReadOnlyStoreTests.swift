import Foundation
import Testing
import RuyioPersistence
import RuyioProtocol

struct ReadOnlyStoreTests {
    @Test func healthOpenDoesNotCreateDirectoriesOrReclaimUploads() throws {
        let directory = temporaryDirectory()
        let document = StoredDocument(collection: "records", id: "r1", body: ["text": "candidate data"])
        do {
            let writable = try PluginStore(directory: directory)
            try writable.put(document)
        }
        let blobs = directory.appendingPathComponent("Blobs.noindex")
        let upload = directory.appendingPathComponent("Uploads.noindex/staged-upload")
        try FileManager.default.removeItem(at: blobs)
        let pending = Data("pending bytes must remain untouched".utf8)
        try pending.write(to: upload)

        let health = try PluginStore(directory: directory, readOnly: true)
        #expect(try health.get(collection: "records", id: "r1") == document)
        #expect(try Data(contentsOf: upload) == pending)
        #expect(!FileManager.default.fileExists(atPath: blobs.path))
        #expect(throws: (any Error).self) { try health.put(document) }
    }

    @Test func healthOpenOfMissingStoreLeavesNoPartialDirectory() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-health-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { _ = try PluginStore(directory: missing, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
