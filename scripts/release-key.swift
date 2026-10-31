// Release signing key for the in-app updater (Ed25519 via CryptoKit).
//
// The private key lives only in the maintainer's login Keychain (stored as
// base64, so it can be backed up with `security find-generic-password -s
// dev.whatsappwork.release-signing -w`). The app ships the public key
// (Info.plist WWUpdatePublicKey) and refuses any update whose DMG
// signature does not verify against it.
//
//   swift scripts/release-key.swift generate     # once; prints the public key
//   swift scripts/release-key.swift public       # prints the public key
//   swift scripts/release-key.swift sign <file>  # prints a base64 signature
import CryptoKit
import Foundation
import Security

let service = "dev.whatsappwork.release-signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-key: \(message)\n".utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let stored = item as? Data,
          let raw = Data(base64Encoded: String(decoding: stored, as: UTF8.self)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail(status == errSecItemNotFound
             ? "no release key in the Keychain; run `generate` first"
             : "cannot read the release key (OSStatus \(status))")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    let attributes: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "WhatsApp Work release signing key",
        kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
        fail(status == errSecDuplicateItem
             ? "a release key already exists; refusing to replace it"
             : "cannot store the key (OSStatus \(status))")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 2:
    let url = URL(fileURLWithPath: arguments[1])
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(url.path)") }
    do {
        print(try loadKey().signature(for: data).base64EncodedString())
    } catch {
        fail("signing failed: \(error)")
    }
default:
    fail("usage: release-key.swift generate | public | sign <file>")
}
