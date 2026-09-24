import Foundation
import Darwin

struct CertificateAuthority: Equatable {
    let certPEM: String
    let keyPEM: String
}

enum CoreBridgeError: LocalizedError {
    case generationFailed
    case serverStartFailed

    var errorDescription: String? {
        switch self {
        case .generationFailed: return AppLocalization.string("无法生成本地证书")
        case .serverStartFailed: return AppLocalization.string("无法启动本地证书服务")
        }
    }
}

enum CoreBridge {
    static func isValidCertificateAuthority(_ authority: CertificateAuthority) -> Bool {
        authority.certPEM.withCString { certificate in
            authority.keyPEM.withCString { key in
                wloccore_validateca(UnsafeMutablePointer(mutating: certificate), UnsafeMutablePointer(mutating: key)) != 0
            }
        }
    }

    static func generateCertificateAuthority() throws -> CertificateAuthority {
        RuntimeLogger.info("APP", "Core.CA", "调用 Go Core 生成 CA")
        let result = wloccore_generateca()
        guard let certPointer = result.r0, let keyPointer = result.r1 else {
            flushLogs(category: "CA")
            throw CoreBridgeError.generationFailed
        }
        defer { free(certPointer); free(keyPointer) }
        RuntimeLogger.info("APP", "Core.CA", "Go Core CA 生成成功")
        flushLogs(category: "CA")
        return CertificateAuthority(certPEM: String(cString: certPointer), keyPEM: String(cString: keyPointer))
    }

    /// 调用 Go Core 做一次模拟 wloc 响应改写测试，验证定位数据是否会被改成目标坐标。
    static func testWlocPatch(lat: Double, lon: Double, accuracy: Int) -> String {
        guard let ptr = wloccore_testpatch(CDouble(lat), CDouble(lon), CInt(accuracy)) else {
            return "error: null result"
        }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    static func flushLogs(category: String) {
        guard let pointer = wloccore_drainlogs() else { return }
        defer { free(pointer) }
        String(cString: pointer).split(separator: "\n").forEach {
            RuntimeLogger.info("CORE", category, String($0))
        }
    }

    static func refreshVerifyToken() -> String {
        guard let ptr = wloccore_refreshverifytoken() else { return "" }
        defer { free(ptr) }
        return String(cString: ptr)
    }
}

final class LocalCertificateServer {
    private var handle: UInt = 0
    private(set) var downloadURL: URL?
    private(set) var probeURL: URL?
    private(set) var leafHash = ""

    deinit { stop() }

    func start(authority: CertificateAuthority) throws {
        if handle != 0 {
            RuntimeLogger.debug("APP", "Certificate.server", "本地证书服务已在运行")
            return
        }
        RuntimeLogger.info("APP", "Certificate.server", "调用 Go Core 启动本地证书服务")
        let newHandle: UInt = authority.certPEM.withCString { certPointer in
            authority.keyPEM.withCString { keyPointer in
                UInt(wloccore_startcertserver(UnsafeMutablePointer(mutating: certPointer), UnsafeMutablePointer(mutating: keyPointer)))
            }
        }
        guard newHandle != 0 else {
            CoreBridge.flushLogs(category: "CertificateServer")
            throw CoreBridgeError.serverStartFailed
        }
        let httpPort = Int(wloccore_certserver_httpport(newHandle))
        let httpsPort = Int(wloccore_certserver_httpsport(newHandle))
        guard httpPort > 0, httpsPort > 0, let hashPointer = wloccore_certserver_leafsha256(newHandle) else {
            _ = wloccore_stopcertserver(newHandle)
            throw CoreBridgeError.serverStartFailed
        }
        defer { free(hashPointer) }
        handle = newHandle
        downloadURL = URL(string: "http://127.0.0.1:\(httpPort)/ca.cer")
        probeURL = URL(string: "https://127.0.0.1:\(httpsPort)/health")
        leafHash = String(cString: hashPointer)
        RuntimeLogger.info("APP", "Certificate.server", "本地证书服务启动成功", details: [
            "httpPort": String(httpPort),
            "httpsPort": String(httpsPort),
            "leafHash": leafHash
        ])
        CoreBridge.flushLogs(category: "CertificateServer")
    }

    func stop() {
        guard handle != 0 else { return }
        let result = wloccore_stopcertserver(handle)
        RuntimeLogger.info("APP", "Certificate.server", "停止本地证书服务", details: ["result": String(result)])
        CoreBridge.flushLogs(category: "CertificateServer")
        handle = 0
        downloadURL = nil
        probeURL = nil
        leafHash = ""
    }
}
