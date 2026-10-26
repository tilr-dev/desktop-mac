// Prints the base64 Ed25519 public key of a Sparkle private key file (generate_keys -x),
// for runners without the key in a Keychain: a 32-byte seed, or the legacy 96 bytes
// (64-byte expanded private key, then the public key).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: sparkle_public_key.swift KEY_FILE") }
guard let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    fail("Not a base64 Sparkle private key file")
}
switch key.count {
case 32:
    guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: key) else { fail("Invalid Ed25519 seed") }
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
case 96:
    print(key.suffix(32).base64EncodedString())
default:
    fail("Unexpected Sparkle private key length \(key.count)")
}
