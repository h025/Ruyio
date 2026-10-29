import CryptoKit
import Foundation

/// A throwaway self-signed code signing identity in its own keychain, the kind a plugin publisher uses
/// without Apple's paid program (A39). The keychain stays out of the user's search list.
enum SigningFixture {
    struct Identity: Sendable {
        var keychain: URL
        /// SHA-1 of the certificate, as `codesign --sign` takes it.
        var hash: String
        var certificateSHA256: String
        var publisherID: String { "cert:" + certificateSHA256 }
    }

    static let first = Result { try make(name: "Ruyio Test Publisher") }
    static let second = Result { try make(name: "Ruyio Other Publisher") }

    static func make(name: String) throws -> Identity {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("signing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let config = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(name)
        [ext]
        basicConstraints = critical, CA:false
        keyUsage = critical, digitalSignature
        extendedKeyUsage = critical, codeSigning
        """
        try config.write(to: work.appendingPathComponent("cert.cnf"), atomically: true, encoding: .utf8)
        // LibreSSL, whose PKCS#12 `security import` reads.
        _ = try output("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-config", "cert.cnf",
                                            "-keyout", "key.pem", "-out", "cert.pem"], cwd: work)
        _ = try output("/usr/bin/openssl", ["x509", "-in", "cert.pem", "-outform", "der", "-out", "cert.der"], cwd: work)
        // Explicit legacy algorithms: `security import` reads these whatever the OpenSSL build defaults to.
        _ = try output("/usr/bin/openssl", ["pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                                            "-inkey", "key.pem", "-in", "cert.pem", "-name", name,
                                            "-out", "identity.p12", "-passout", "pass:test"], cwd: work)
        let keychain = work.appendingPathComponent("test.keychain-db")
        _ = try output("/usr/bin/security", ["create-keychain", "-p", "", keychain.path], cwd: work)
        _ = try output("/usr/bin/security", ["set-keychain-settings", keychain.path], cwd: work)
        _ = try output("/usr/bin/security", ["unlock-keychain", "-p", "", keychain.path], cwd: work)
        _ = try output("/usr/bin/security", ["import", "identity.p12", "-k", keychain.path, "-P", "test", "-T", "/usr/bin/codesign"], cwd: work)
        _ = try output("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", "", keychain.path], cwd: work)
        let identities = try output("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain.path], cwd: work)
        guard let line = identities.split(separator: "\n").first(where: { $0.contains("\"\(name)\"") }),
              let hash = line.split(separator: " ").dropFirst().first else {
            throw CocoaError(.fileReadUnknown)
        }
        let der = try Data(contentsOf: work.appendingPathComponent("cert.der"))
        return Identity(keychain: keychain, hash: String(hash),
                        certificateSHA256: SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
    }

    static func output(_ tool: String, _ args: [String], cwd: URL) throws -> String {
        try ToolFailure.run(tool, args, cwd: cwd)
    }
}
