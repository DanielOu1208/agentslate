import AgentSlateClient
import Foundation
import Security

enum KeychainStore {
  private static let bridgeService = "com.danielou.AgentSlate.bridge"
  private static let bridgeAccount = "bridge-credential"
  private static let dictationService = "com.danielou.AgentSlate.dictation"
  private static let dictationAccount = "cloud-api-keys"

  static func loadBridge() -> BridgeCredential? {
    load(BridgeCredential.self, service: bridgeService, account: bridgeAccount)
  }

  static func saveBridge(_ credential: BridgeCredential) throws {
    try save(credential, service: bridgeService, account: bridgeAccount)
  }

  static func deleteBridge() throws {
    try delete(service: bridgeService, account: bridgeAccount)
  }

  static func loadDictation() -> DictationCredentials? {
    load(DictationCredentials.self, service: dictationService, account: dictationAccount)
  }

  static func saveDictation(_ credentials: DictationCredentials) throws {
    try save(credentials, service: dictationService, account: dictationAccount)
  }

  static func deleteDictation() throws {
    try delete(service: dictationService, account: dictationAccount)
  }

  private static func load<Value: Decodable>(
    _ type: Value.Type,
    service: String,
    account: String
  ) -> Value? {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary,
      &item
    )
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func save<Value: Encodable>(
    _ value: Value,
    service: String,
    account: String
  ) throws {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ] as CFDictionary
    let data = try JSONEncoder().encode(value)
    let status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw keychainError(status) }

    let addStatus = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData: data,
      ] as CFDictionary,
      nil
    )
    guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
  }

  private static func delete(service: String, account: String) throws {
    let status = SecItemDelete(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ] as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
  }
}
