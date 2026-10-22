//
//  CertificateTrust.swift
//  ldap-studio
//
//  What there is to trust when a server's certificate isn't accepted, and
//  what trusting it changes on the connection. Apart from the sheet that
//  asks (CertificateTrustSheet), so the test-server checks can use it too.
//

import CryptoKit
import Foundation
import Security

/// One certificate the server presented, ready to show.
nonisolated struct PresentedCertificate: Identifiable, Hashable, Sendable {
    let der: Data
    /// Lowercase hex SHA-256 of `der`.
    let sha256: String
    /// The certificate's name, the way Keychain Access shows it.
    let name: String
    var id: String { sha256 }

    init(der: Data) {
        self.der = der
        sha256 = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        name = SecCertificateCreateWithData(nil, der as CFData)
            .flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Unnamed certificate"
    }
}

/// What the user chose to trust for a connection.
nonisolated enum CertificateTrustDecision: Equatable, Sendable {
    /// Every server this certificate authority (DER) issued a certificate
    /// to, as long as it was issued to a name `hostNames` accepts.
    case certificateAuthority(Data, hostNames: CertificateHostNames)
    /// The one server certificate with this SHA-256 (lowercase hex).
    case certificate(sha256: String)
    /// Certificates issued to the names `hostNames` accepts.
    case hostNames(CertificateHostNames)
}

/// Why a probed certificate isn't accepted, as far as the probe can tell.
nonisolated enum CertificateTrustProblem: Equatable, Sendable {
    /// No certificate authority the connection trusts issued it.
    case untrustedIssuer
    /// It was issued to another name than the host.
    case otherHostName
    /// It has expired or isn't valid yet, which no certificate authority
    /// can make up for.
    case expired
    /// Its chain fails for another reason (a certificate authority in it
    /// expired, say), given in words — trusting another one won't help.
    case invalidChain(String)
    /// Nothing: it's accepted now. Another server behind the same host name
    /// may have answered the connection that was refused.
    case none
}

extension LdapCertificate {
    /// The certificate authorities the server sent along with its own
    /// certificate, the one nearest the root first.
    var presentedAuthorities: [PresentedCertificate] {
        chain.dropFirst().reversed().map(PresentedCertificate.init)
    }

    /// The strictest host-name rule that accepts this certificate.
    var hostNamesNeeded: CertificateHostNames {
        if !hostMismatch { return .exact }
        return issuedToSubdomain ? .subdomains : .any
    }

    func problem(for connection: SavedConnection) -> CertificateTrustProblem {
        // The pinned certificate itself is accepted whatever else is wrong
        // with it — the probe reached the server it came from.
        if let pin = connection.trustedCertSHA256,
           pin.lowercased().filter({ $0 != ":" && $0 != " " }) == sha256 {
            return .none
        }
        if expired { return .expired }
        if !chainTrusted { return untrustedIssuer ? .untrustedIssuer : .invalidChain(chainProblem) }
        if hostNamesNeeded > connection.certificateHostNames { return .otherHostName }
        return .none
    }
}

extension SavedConnection {
    /// Whether the user has trusted anything for this connection's TLS.
    var hasTrustedCertificates: Bool {
        trustedCertSHA256 != nil || !trustedCACertificates.isEmpty
    }

    mutating func trust(_ decision: CertificateTrustDecision) {
        switch decision {
        case let .certificateAuthority(der, hostNames):
            if !trustedCACertificates.contains(der) { trustedCACertificates.append(der) }
            // A server certificate trusted on its own before is covered now
            // — and keeping it would only hide that it's been replaced.
            trustedCertSHA256 = nil
            certificateHostNames = max(certificateHostNames, hostNames)
        case let .certificate(sha256):
            trustedCertSHA256 = sha256
        case let .hostNames(hostNames):
            certificateHostNames = max(certificateHostNames, hostNames)
        }
    }
}
