//
//  CertificateTrustSheet.swift
//  ldap-studio
//

import SwiftUI

/// Shown when a TLS / StartTLS connection is refused over the server's
/// certificate. It probes the certificate (verification off, read-only),
/// works out why it isn't accepted and offers the fix that lasts: trusting
/// the certificate authority that issued it, for this one connection, so
/// every server it issued a certificate to is accepted — all the domain
/// controllers an Active Directory domain name leads to, and the
/// certificates that replace theirs. Trusting only the one certificate is
/// the fallback, for a self-signed server or one that doesn't send its
/// certificate authority.
struct CertificateTrustSheet: View {
    /// The connection as it was refused — what it already trusts decides
    /// what's left to offer.
    let connection: SavedConnection
    /// How to reach the server — the SSH tunnel, the trusted certificate
    /// authorities. `connection.ldapOptions` unless the caller has fresher
    /// ones (the connection editor's unsaved SSH password).
    var options: LDAPConnectionOptions?
    let onTrust: (CertificateTrustDecision) -> Void
    /// For when the certificate turns out to be accepted after all.
    let onRetry: () -> Void
    /// When set, the sheet renders this instead of probing the server —
    /// for previews and tests.
    var previewCertificate: LdapCertificate?

    @Environment(\.dismiss) private var dismiss

    @State private var certificate: LdapCertificate?
    @State private var loadError: String?
    /// The certificate authority to trust, when the server sent several.
    @State private var authorityID: PresentedCertificate.ID?

    private var host: String { connection.host }
    private var port: UInt16 { UInt16(clamping: connection.port) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(certificate.map { title(for: $0) } ?? "Untrusted Certificate")
                        .font(.headline)
                    Text("\(host):\(String(port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            Group {
                if let certificate {
                    details(certificate)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't Read Certificate", systemImage: "xmark.octagon")
                    } description: {
                        Text(loadError)
                    }
                } else {
                    ProgressView("Reading certificate…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 240)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let certificate {
                    buttons(for: certificate)
                }
            }
            .padding()
        }
        .frame(width: 560)
        .task {
            if let previewCertificate {
                certificate = previewCertificate
                return
            }
            do {
                certificate = try await probeCertificate(
                    host: host, port: port, useSsl: connection.useSSL,
                    startTLS: connection.useStartTLS,
                    options: options ?? connection.ldapOptions
                )
            } catch {
                loadError = "\(error)"
            }
        }
    }

    // MARK: What to offer

    /// The ones not trusted already — trusting those again changes nothing.
    private func authorities(_ cert: LdapCertificate) -> [PresentedCertificate] {
        cert.presentedAuthorities.filter { !connection.trustedCACertificates.contains($0.der) }
    }

    /// The certificate authority the primary button trusts: the one picked,
    /// otherwise the one nearest the root, which covers the most servers.
    private func selectedAuthority(_ cert: LdapCertificate) -> PresentedCertificate? {
        let all = authorities(cert)
        return all.first { $0.id == authorityID } ?? all.first
    }

    /// Trusting a certificate authority for a certificate issued to another
    /// name only gets the connection through with the host-name check off.
    private func trustingAuthorityAcceptsOtherNames(_ cert: LdapCertificate) -> Bool {
        cert.hostMismatch && connection.checksCertificateHostName
    }

    /// Only when nothing was trusted for this connection before: a
    /// certificate that replaces one the user trusted is worth a look
    /// rather than a reflexive Return.
    private var isFirstSighting: Bool { !connection.hasTrustedCertificates }

    @ViewBuilder
    private func buttons(for cert: LdapCertificate) -> some View {
        switch cert.problem(for: connection) {
        case .untrustedIssuer:
            if let authority = selectedAuthority(cert) {
                Button("Trust Only This Certificate") { decide(.certificate(sha256: cert.sha256)) }
                primary("Trust Certificate Authority") {
                    decide(.certificateAuthority(
                        authority.der,
                        acceptingOtherHostNames: trustingAuthorityAcceptsOtherNames(cert)
                    ))
                }
            } else {
                primary("Trust This Certificate") { decide(.certificate(sha256: cert.sha256)) }
            }
        case .otherHostName:
            Button("Trust Only This Certificate") { decide(.certificate(sha256: cert.sha256)) }
            primary("Accept Other Host Names") { decide(.otherHostNames) }
        case .expired, .invalidChain:
            primary("Trust This Certificate") { decide(.certificate(sha256: cert.sha256)) }
        case .none:
            Button("Try Again") {
                dismiss()
                onRetry()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        if isFirstSighting {
            Button(title, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
        }
    }

    private func decide(_ decision: CertificateTrustDecision) {
        onTrust(decision)
        dismiss()
    }

    // MARK: Explaining it

    private func title(for cert: LdapCertificate) -> String {
        switch cert.problem(for: connection) {
        case .untrustedIssuer: connection.trustedCertSHA256 != nil ? "Certificate Changed" : "Untrusted Certificate"
        case .otherHostName: "Certificate for Another Name"
        case .expired: "Expired Certificate"
        case .invalidChain: "Certificate Can't Be Verified"
        case .none: "Certificate Trusted"
        }
    }

    private func explanation(for cert: LdapCertificate) -> String {
        switch cert.problem(for: connection) {
        case .untrustedIssuer:
            var lead: String
            if connection.trustedCertSHA256 != nil {
                lead = """
                    The server presented a different certificate from the one you trusted for this \
                    connection. That's expected when the certificate was renewed, or when \(host) leads \
                    to several servers (an Active Directory domain name, for example) and another one \
                    answered. It can also mean someone is intercepting the connection, so check the \
                    details below first.
                    """
            } else if !connection.trustedCACertificates.isEmpty {
                lead = "This certificate wasn't issued by a certificate authority you trust for this connection."
            } else {
                lead = """
                    Your Mac doesn't trust the certificate authority that issued this certificate, \
                    usually because it's your organization's own.
                    """
            }
            if selectedAuthority(cert) != nil {
                lead += """
                    \n\nTrusting the certificate authority accepts every server it issued a certificate \
                    to on this connection, so other servers behind \(host) and renewed certificates keep \
                    working.
                    """
            } else if cert.selfSigned {
                lead += """
                    \n\nThe certificate is self-signed, so only this exact certificate can be trusted. \
                    If it's replaced, you'll be asked again.
                    """
            } else {
                lead += """
                    \n\nThe server didn't send the certificate authority that issued its certificate, so \
                    only this exact certificate can be trusted. If it's renewed, or another server \
                    answers for \(host), you'll be asked again.
                    """
            }
            return lead
        case .otherHostName:
            return """
                The certificate comes from a certificate authority this connection trusts, but it was \
                issued to a different name than \(host). Accepting other host names turns that check off \
                for this connection: a certificate from a trusted certificate authority is then accepted \
                whatever name it was issued to.
                """
        case .expired:
            return """
                This certificate has expired or isn't valid yet, which no certificate authority can make \
                up for. You can still trust this exact certificate. Ask the server's administrator to \
                renew it.
                """
        case let .invalidChain(problem):
            return """
                This certificate can't be verified: \(problem). Trusting another certificate authority \
                won't change that. You can still trust this exact certificate. Ask the server's \
                administrator to fix its certificate chain.
                """
        case .none:
            return """
                This server's certificate is accepted for this connection now. Another server behind \
                \(host) may have answered the first time, so try again.
                """
        }
    }

    @ViewBuilder
    private func details(_ cert: LdapCertificate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(explanation(for: cert))
                .fixedSize(horizontal: false, vertical: true)

            let reasons = warnings(for: cert)
            if !reasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                }
            }

            GroupBox("Server certificate") {
                VStack(alignment: .leading, spacing: 4) {
                    row("Subject", cert.subject)
                    row("Issuer", cert.issuer)
                    row("Valid from", cert.notBefore)
                    row("Valid until", cert.notAfter)
                    row("SHA-256", NewConnectionSheet.shortFingerprint(cert.sha256))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if cert.problem(for: connection) == .untrustedIssuer, let selected = selectedAuthority(cert) {
                GroupBox("Certificate authority") {
                    VStack(alignment: .leading, spacing: 6) {
                        let all = authorities(cert)
                        if all.count > 1 {
                            Picker("Trust", selection: Binding(
                                get: { selected.id },
                                set: { authorityID = $0 }
                            )) {
                                ForEach(all) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Text("Higher up the list covers more servers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            row("Name", selected.name)
                        }
                        row("SHA-256", NewConnectionSheet.shortFingerprint(selected.sha256))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if trustingAuthorityAcceptsOtherNames(cert) {
                    Label(
                        "This certificate was issued to a different name than \(host), so trusting the certificate authority also turns off the host-name check for this connection.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func warnings(for cert: LdapCertificate) -> [String] {
        var out: [String] = []
        if cert.selfSigned { out.append("Self-signed") }
        if cert.expired { out.append("Expired / not yet valid") }
        if cert.hostMismatch { out.append("Name mismatch") }
        return out
    }
}

#Preview {
    CertificateTrustSheet(
        connection: SavedConnection(name: "Preview", host: "ldap.internal.example.com", port: 636,
                                    useSSL: true, baseDN: "", bindDN: ""),
        onTrust: { print("trusted \($0)") },
        onRetry: {},
        previewCertificate: LdapCertificate(
            subject: "CN=ldap.internal.example.com,O=Example Corp,C=US",
            issuer: "CN=Example Corp Internal CA,O=Example Corp,C=US",
            sha256: "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff001",
            notBefore: "Jan  1 00:00:00 2025 GMT",
            notAfter: "Jan  1 00:00:00 2028 GMT",
            selfSigned: false,
            expired: false,
            hostMismatch: true,
            chain: [],
            chainTrusted: false,
            untrustedIssuer: true,
            chainProblem: "it wasn't issued by a certificate authority trusted for this connection"
        )
    )
}
