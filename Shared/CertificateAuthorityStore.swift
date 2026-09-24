import Foundation
import Security

protocol CertificateAuthorityKeychain {
    func load() throws -> CertificateAuthority?
    func save(_ authority: CertificateAuthority) throws
    func remove() throws
}

enum CertificateAuthorityStoreError: LocalizedError {
    case invalidAuthority
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAuthority: return AppLocalization.string("本地 CA 证书或私钥无效")
        case let .keychain(status): return AppLocalization.string("无法写入设备钥匙串（\(status)）")
        }
    }
}

final class DeviceCertificateAuthorityKeychain: CertificateAuthorityKeychain {
    private enum Item {
        static let service = "com.paopaolabs.location-spoofer.certificate-authority"
        static let certificateAccount = "root-ca-certificate"
        static let keyAccount = "root-ca-private-key"
    }

    func load() throws -> CertificateAuthority? {
        guard let certPEM = try load(account: Item.certificateAccount),
              let keyPEM = try load(account: Item.keyAccount) else {
            return nil
        }
        return CertificateAuthority(certPEM: certPEM, keyPEM: keyPEM)
    }

    func save(_ authority: CertificateAuthority) throws {
        try remove()
        do {
            try save(authority.certPEM, account: Item.certificateAccount)
            try save(authority.keyPEM, account: Item.keyAccount)
        } catch {
            try? remove()
            throw error
        }
    }

    func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Item.service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CertificateAuthorityStoreError.keychain(status)
        }
    }

    private func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Item.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CertificateAuthorityStoreError.keychain(status)
        }
        return value
    }

    private func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Item.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CertificateAuthorityStoreError.keychain(status) }
    }
}

final class CertificateAuthorityStore {
    private let directory: URL
    private let generator: () throws -> CertificateAuthority
    private let validator: (CertificateAuthority) -> Bool
    private let keychain: CertificateAuthorityKeychain
    private let certificateURL: URL
    private let keyURL: URL

    init(
        directory: URL = AppGroup.containerURL.appendingPathComponent("CertificateAuthority", isDirectory: true),
        keychain: CertificateAuthorityKeychain = DeviceCertificateAuthorityKeychain(),
        generator: @escaping () throws -> CertificateAuthority = CoreBridge.generateCertificateAuthority,
        validator: @escaping (CertificateAuthority) -> Bool = CoreBridge.isValidCertificateAuthority
    ) {
        self.directory = directory
        self.keychain = keychain
        self.generator = generator
        self.validator = validator
        self.certificateURL = directory.appendingPathComponent("ca-cert.pem")
        self.keyURL = directory.appendingPathComponent("ca-key.pem")
    }

    func ensure() throws -> CertificateAuthority {
        if let authority = try loadValidKeychainAuthority() {
            removeLegacyFilesBestEffort()
            RuntimeLogger.debug("SHARED", "Certificate.store", "复用设备钥匙串中的 CA")
            return authority
        }

        if let legacy = try loadLegacyAuthority(), validator(legacy) {
            try keychain.save(legacy)
            removeLegacyFilesBestEffort()
            RuntimeLogger.info("SHARED", "Certificate.store", "旧 CA 已迁移到设备钥匙串")
            return legacy
        }

        let authority = try generator()
        guard validator(authority) else { throw CertificateAuthorityStoreError.invalidAuthority }
        try keychain.save(authority)
        removeLegacyFilesBestEffort()
        RuntimeLogger.info("SHARED", "Certificate.store", "已生成并保存设备专属 CA")
        return authority
    }

    func load() throws -> CertificateAuthority? {
        try loadValidKeychainAuthority()
    }

    func reset() throws {
        try removeLegacyFiles()
        try keychain.remove()
        RuntimeLogger.info("SHARED", "Certificate.store", "已删除设备 CA，等待重新生成")
    }

    private func loadValidKeychainAuthority() throws -> CertificateAuthority? {
        guard let authority = try keychain.load() else { return nil }
        guard validator(authority) else {
            RuntimeLogger.warning("SHARED", "Certificate.store", "钥匙串中的 CA 无效，准备回退")
            try? keychain.remove()
            return nil
        }
        return authority
    }

    private func loadLegacyAuthority() throws -> CertificateAuthority? {
        guard FileManager.default.fileExists(atPath: certificateURL.path),
              FileManager.default.fileExists(atPath: keyURL.path) else {
            return nil
        }
        return CertificateAuthority(
            certPEM: try String(contentsOf: certificateURL, encoding: .utf8),
            keyPEM: try String(contentsOf: keyURL, encoding: .utf8)
        )
    }

    private func removeLegacyFilesBestEffort() {
        do {
            try removeLegacyFiles()
        } catch {
            RuntimeLogger.error("SHARED", "Certificate.store", "删除旧 CA 文件失败，将在下次启动重试", error: error)
        }
    }

    private func removeLegacyFiles() throws {
        let fileManager = FileManager.default
        for url in [keyURL, certificateURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }
}
