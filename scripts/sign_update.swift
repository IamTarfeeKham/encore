// Signs a release zip for in-app updates: prints a base64 Ed25519 signature.
// Usage: swift scripts/sign_update.swift <private-key-file> <zip>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3,
      let keyText = try? String(contentsOfFile: args[1], encoding: .utf8),
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData),
      let zip = FileManager.default.contents(atPath: args[2])
else { FileHandle.standardError.write(Data("usage: sign_update.swift <key> <zip>\n".utf8)); exit(1) }
print(try key.signature(for: zip).base64EncodedString())
