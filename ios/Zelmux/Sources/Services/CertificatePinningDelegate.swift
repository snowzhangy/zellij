import CryptoKit
import Foundation
import Security

final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    var expectedPublicKeyHash: String?
    var observedPublicKeyHash: ((String) -> Void)?
    private(set) var untrustedPublicKeyHash: String?
    private(set) var certificateMismatch: (observed: String, expected: String)?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let hash = Self.publicKeyHash(from: trust)
        if let hash {
            observedPublicKeyHash?(hash)
        }

        if let expectedPublicKeyHash {
            if hash == expectedPublicKeyHash {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                if let hash {
                    certificateMismatch = (observed: hash, expected: expectedPublicKeyHash)
                }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        untrustedPublicKeyHash = hash
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private static func publicKeyHash(from trust: SecTrust) -> String? {
        guard let key = SecTrustCopyKey(trust),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
