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
/// the alternative, and the only option for a self-signed server or one
/// that doesn't send its certificate authority.
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
    /// Where there are two ways to fix it, whether the first (the lasting
    /// one) is chosen.
    @State private var choosesFirst = true
    /// The certificate authority to trust, when the server sent several.
    @State private var authorityID: PresentedCertificate.ID?
    @State private var showsDetails = false
    /// The height of everything above the footer, so the sheet is as tall
    /// as that and only scrolls when the window is shorter.
    @State private var contentHeight: CGFloat = 0

    private var host: String { connection.host }
    private var port: UInt16 { UInt16(clamping: connection.port) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: contentHeight)
            Divider()
            footer
        }
        .frame(width: 500)
        .task {
            do {
                let probed: LdapCertificate
                if let previewCertificate {
                    probed = previewCertificate
                } else {
                    probed = try await probeCertificate(
                        host: host, port: port, useSsl: connection.useSSL,
                        startTLS: connection.useStartTLS,
                        options: options ?? connection.ldapOptions
                    )
                }
                // Accepting any name is never the choice made for the user.
                choosesFirst = !widensToAnyName(probed)
                // A certificate that replaced one the user trusted: show what
                // it is straight away, so it gets compared before it's trusted.
                showsDetails = connection.trustedCertSHA256 != nil && probed.problem(for: connection) != .none
                certificate = probed
            } catch {
                loadError = "\(error)"
            }
        }
    }

    // MARK: Layout

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let certificate {
                fixes(for: certificate)
                DisclosureGroup("Certificate Details", isExpanded: $showsDetails) {
                    details(certificate)
                        .padding(.top, 8)
                }
            } else if loadError == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func fixes(for cert: LdapCertificate) -> some View {
        switch cert.problem(for: connection) {
        case .untrustedIssuer:
            if let authority = selectedAuthority(cert) {
                VStack(alignment: .leading, spacing: 8) {
                    choice(
                        first: true,
                        title: "Trust \(authority.name)",
                        isRecommended: !widensToAnyName(cert),
                        detail: authorityDetail(cert),
                        warning: widensToAnyName(cert) ? Self.anyNameWarning : nil
                    )
                    if authorities(cert).count > 1 && choosesFirst {
                        Picker("Certificate authority", selection: Binding(
                            get: { authority.id },
                            set: { authorityID = $0 }
                        )) {
                            ForEach(authorities(cert)) { Text($0.name).tag($0.id) }
                        }
                        .padding(.leading, 34)
                    }
                    onlyThisCertificateChoice
                }
            } else {
                note(cert.selfSigned
                    ? "A self-signed certificate vouches only for itself, so only this exact certificate can be trusted. You'll be asked again if it's replaced."
                    : "The server didn't send the certificate authority that issued it, so only this exact certificate can be trusted. You'll be asked again if it's renewed or another server answers.")
            }
        case .otherHostName:
            VStack(alignment: .leading, spacing: 8) {
                if cert.hostNamesNeeded == .subdomains {
                    choice(
                        first: true,
                        title: "Accept servers under \(host)",
                        isRecommended: true,
                        detail: "Certificates issued to a server one level under \(host), like \(serverName(cert)), are accepted."
                    )
                } else {
                    choice(
                        first: true,
                        title: "Accept any host name",
                        detail: "For when the server's certificates never name \(host).",
                        warning: Self.anyNameWarning
                    )
                }
                onlyThisCertificateChoice
            }
        case .expired, .invalidChain:
            note("Trusting a certificate authority can't fix this. You can still trust this exact certificate, or ask the server's administrator to fix it.")
        case .none:
            EmptyView()
        }
    }

    private var onlyThisCertificateChoice: some View {
        choice(
            first: false,
            title: "Trust only this certificate",
            detail: "You'll be asked again when it's renewed or another server answers."
        )
    }

    /// One of two ways to fix it, as a radio-style card.
    private func choice(first: Bool, title: String, isRecommended: Bool = false,
                        detail: String, warning: String? = nil) -> some View {
        let isSelected = choosesFirst == first
        return Button {
            choosesFirst = first
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .fontWeight(.medium)
                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func details(_ cert: LdapCertificate) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            detailRow("Issued to", cert.subject)
            detailRow("Issued by", cert.issuer)
            detailRow("Valid", "\(cert.notBefore) – \(cert.notAfter)")
            detailRow("SHA-256", Self.fingerprint(cert.sha256), monospaced: true)
            ForEach(cert.presentedAuthorities) { authority in
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                detailRow("Authority", authority.name)
                detailRow("SHA-256", Self.fingerprint(authority.sha256), monospaced: true)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
        .padding(16)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let certificate, certificate.problem(for: connection) == .none {
            Button("Try Again") {
                dismiss()
                onRetry()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        } else {
            let action = certificate.flatMap(decision(for:))
            // Return never turns the host-name check off, either.
            let widens = choosesFirst && certificate.map(widensToAnyName) == true
            let button = Button(primaryTitle) {
                if let action { decide(action) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(action == nil)
            // Only when nothing was trusted for this connection before: a
            // certificate that replaces one the user trusted is worth a look
            // rather than a reflexive Return.
            if isFirstSighting && !widens {
                button.keyboardShortcut(.defaultAction)
            } else {
                button
            }
        }
    }

    // MARK: What to offer

    /// The ones not trusted already — trusting those again changes nothing.
    private func authorities(_ cert: LdapCertificate) -> [PresentedCertificate] {
        cert.presentedAuthorities.filter { !connection.trustedCACertificates.contains($0.der) }
    }

    /// The certificate authority to trust: the one picked, otherwise the one
    /// nearest the root, which covers the most servers.
    private func selectedAuthority(_ cert: LdapCertificate) -> PresentedCertificate? {
        let all = authorities(cert)
        return all.first { $0.id == authorityID } ?? all.first
    }

    private var isFirstSighting: Bool { !connection.hasTrustedCertificates }

    /// Whether the first choice would turn the host-name check off — the
    /// certificate needs any name and the connection doesn't accept that
    /// already.
    private func widensToAnyName(_ cert: LdapCertificate) -> Bool {
        cert.hostNamesNeeded == .any && connection.certificateHostNames != .any
    }

    /// What the primary button does, given the choice made.
    private func decision(for cert: LdapCertificate) -> CertificateTrustDecision? {
        let onlyThis = CertificateTrustDecision.certificate(sha256: cert.sha256)
        switch cert.problem(for: connection) {
        case .untrustedIssuer:
            guard let authority = selectedAuthority(cert), choosesFirst else { return onlyThis }
            return .certificateAuthority(authority.der, hostNames: cert.hostNamesNeeded)
        case .otherHostName:
            return choosesFirst ? .hostNames(cert.hostNamesNeeded) : onlyThis
        case .expired, .invalidChain:
            return onlyThis
        case .none:
            return nil
        }
    }

    private var primaryTitle: String {
        guard let certificate else { return "Trust" }
        switch certificate.problem(for: connection) {
        case .untrustedIssuer:
            return selectedAuthority(certificate) != nil && choosesFirst ? "Trust Authority" : "Trust Certificate"
        case .otherHostName:
            return choosesFirst ? "Accept" : "Trust Certificate"
        case .expired, .invalidChain:
            return "Trust Certificate"
        case .none:
            return "Try Again"
        }
    }

    private func decide(_ decision: CertificateTrustDecision) {
        onTrust(decision)
        dismiss()
    }

    // MARK: Words

    /// The name the server's certificate is issued to.
    private func serverName(_ cert: LdapCertificate) -> String {
        cert.chain.first.map { PresentedCertificate(der: $0).name } ?? host
    }

    private func authorityDetail(_ cert: LdapCertificate) -> String {
        switch cert.hostNamesNeeded {
        case .exact:
            "Accepts any server it issued a certificate to, so renewed certificates keep working."
        case .subdomains:
            "Accepts every server under \(host) it issued a certificate to, so other domain controllers and renewed certificates keep working."
        case .any:
            "Accepts any server it issued a certificate to, so renewed certificates keep working."
        }
    }

    private var title: String {
        if loadError != nil { return "Couldn't Read Certificate" }
        guard let certificate else { return "Reading Certificate…" }
        let problem = certificate.problem(for: connection)
        if connection.trustedCertSHA256 != nil && problem != .none { return "Certificate Changed" }
        switch problem {
        case .untrustedIssuer: return "Untrusted Certificate"
        case .otherHostName: return "Certificate for Another Name"
        case .expired: return "Expired Certificate"
        case .invalidChain: return "Certificate Can't Be Verified"
        case .none: return "Certificate Trusted"
        }
    }

    private var summary: String {
        if let loadError { return loadError }
        guard let cert = certificate else { return "\(host):\(String(port))" }
        let problem = cert.problem(for: connection)
        let reason = summary(of: problem, cert)
        // However else it's wrong, a certificate that replaced the one the
        // user trusted could be someone intercepting the connection.
        guard connection.trustedCertSHA256 != nil, problem != .none, problem != .untrustedIssuer else { return reason }
        return "\(reason) It replaced the certificate you trusted, which can mean someone is intercepting the connection. Compare the details below with the server's before trusting it."
    }

    private func summary(of problem: CertificateTrustProblem, _ cert: LdapCertificate) -> String {
        let name = serverName(cert)
        switch problem {
        case .untrustedIssuer:
            if connection.trustedCertSHA256 != nil {
                return "\(name) presented a different certificate from the one you trusted. That's expected after a renewal, or when another server behind \(host) answers, but it can also mean someone is intercepting the connection. Compare the details below with the server's before trusting it."
            }
            if !connection.trustedCACertificates.isEmpty {
                return "\(name)'s certificate wasn't issued by a certificate authority you trust for this connection."
            }
            if cert.selfSigned { return "\(name) uses a self-signed certificate." }
            let issuer = cert.chain.dropFirst().first.map { PresentedCertificate(der: $0).name }
            return "\(name)'s certificate was issued by \(issuer ?? "a certificate authority"), which your Mac doesn't trust."
        case .otherHostName:
            return "The certificate is trusted, but it's issued to \(name), not \(host)."
        case .expired:
            return "\(name)'s certificate is only valid from \(cert.notBefore) to \(cert.notAfter)."
        case let .invalidChain(problem):
            return "\(name)'s certificate can't be verified: \(problem)."
        case .none:
            return "It's accepted now. Another server behind \(host) probably answered the first time."
        }
    }

    private var symbol: String {
        if loadError != nil { return "xmark.shield" }
        guard let certificate else { return "lock.shield" }
        return certificate.problem(for: connection) == .none ? "checkmark.shield" : "lock.trianglebadge.exclamationmark"
    }

    private var tint: Color {
        if loadError != nil { return .red }
        guard let certificate else { return .secondary }
        return certificate.problem(for: connection) == .none ? .green : .orange
    }

    static let anyNameWarning = "The host name won't be checked: a certificate from any authority your Mac or this connection trusts is accepted, whatever name it's issued to."

    /// "AB:CD:…" — the whole fingerprint, to compare against the server's.
    static func fingerprint(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return hex[start..<end].uppercased()
        }.joined(separator: ":")
    }
}

#Preview {
    CertificateTrustSheet(
        connection: SavedConnection(name: "Preview", host: "corp.example.com", port: 636,
                                    useSSL: true, baseDN: "", bindDN: ""),
        onTrust: { print("trusted \($0)") },
        onRetry: {},
        previewCertificate: LdapCertificate(
            subject: "CN=dc07.corp.example.com",
            issuer: "CN=Example Enterprise CA 1,DC=example,DC=com",
            sha256: "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00",
            notBefore: "Jan  1 00:00:00 2026 GMT",
            notAfter: "Jan  1 00:00:00 2027 GMT",
            selfSigned: false,
            expired: false,
            hostMismatch: true,
            chain: [],
            chainTrusted: false,
            untrustedIssuer: true,
            chainProblem: "it wasn't issued by a certificate authority trusted for this connection",
            issuedToSubdomain: true
        )
    )
}
