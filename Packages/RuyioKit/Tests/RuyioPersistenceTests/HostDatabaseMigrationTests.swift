import Foundation
import GRDB
import Testing
@testable import RuyioPersistence
import RuyioCore

struct HostDatabaseMigrationTests {
    /// Settings saved before identities were introduced follow their installed plugin to the new key.
    @Test func pluginSettingsSurviveTheIdentityMigration() throws {
        let url = temporaryDirectory().appendingPathComponent("Host.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try HostDatabase.migrator.migrate(queue, upTo: "v2-markets")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO installed_plugin (pluginID, manifest, installPath, executablePath, version, signingIdentifier,
                    installationState, activationState, updateState, sourceState, updateChannel, installedAt, updatedAt)
                VALUES ('app.ruyio.finder-essentials', '{}', '/x', '/x', '1.0.0', 'app.ruyio.finder-essentials',
                    'installed', 'enabled', 'none', 'linked', 'bundledWithHost', '2026-10-27 00:00:00', '2026-10-27 00:00:00')
                """)
            try db.execute(sql: "INSERT INTO plugin_setting (pluginID, key, value) VALUES ('app.ruyio.finder-essentials', 'app.editor', '\"com.apple.TextEdit\"')")
            try db.execute(sql: "INSERT INTO plugin_setting (pluginID, key, value) VALUES ('org.example.gone', 'k', '1')")
        }
        try queue.close()

        let database = try HostDatabase(url: url)
        #expect(try database.pluginSettings(PluginID("app.ruyio.finder-essentials"))["app.editor"] == .string("com.apple.TextEdit"))
        #expect(try database.pluginSettings(PluginID("org.example.gone")).isEmpty)
    }
}
