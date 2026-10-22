//
//  MCPAttributePolicy.swift
//  ldap-studio
//
//  Which attributes an agent never sees. Read-only isn't the same as
//  harmless: a bind that may read password hashes, LAPS passwords or
//  BitLocker recovery keys would hand them to the agent along with
//  everything else. These are left out of every result, can't be asked
//  for, and can't appear in a search filter either — a filter like
//  (ms-Mcs-AdmPwd=a*) would otherwise leak a value one guess at a time.
//

import Foundation

nonisolated struct MCPAttributePolicy: Sendable {
    /// Secrets on the common directory servers, lowercased.
    static let alwaysHidden: [String] = [
        // Standard
        "userPassword", "authPassword", "userPKCS12", "pwdHistory",
        // Active Directory
        "unicodePwd", "dBCSPwd", "ntPwdHistory", "lmPwdHistory", "supplementalCredentials",
        "ms-Mcs-AdmPwd", "msLAPS-Password", "msLAPS-EncryptedPassword",
        "msLAPS-EncryptedPasswordHistory", "msLAPS-EncryptedDSRMPassword",
        "msLAPS-EncryptedDSRMPasswordHistory", "msFVE-RecoveryPassword", "msFVE-KeyPackage",
        "msTPM-OwnerInformation", "msTPM-TpmInformationForComputer", "msDS-ManagedPassword",
        "msPKIAccountCredentials", "msPKIDPAPIMasterKeys", "msSFU30Password", "unixUserPassword",
        "trustAuthIncoming", "trustAuthOutgoing", "initialAuthIncoming", "initialAuthOutgoing",
        "currentValue", "priorValue",
        // Samba, Kerberos, FreeIPA, 389 DS, OpenLDAP config, OATH, RADIUS
        "sambaNTPassword", "sambaLMPassword", "sambaPasswordHistory",
        "krbPrincipalKey", "krbMKey", "krb5Key", "ipaNTHash", "ipatokenOTPkey",
        "nsSymmetricKey", "nsds5ReplicaCredentials", "nsslapd-rootpw", "olcRootPW",
        "oathSecret", "radiusTunnelPassword",
    ]

    private let hidden: Set<String>
    /// The server's schema was read, so numeric OIDs (and alias names) of
    /// the hidden attributes are known too. Without it, an OID can't be
    /// checked, so it isn't accepted at all.
    let knowsSchema: Bool

    init(extraHidden: [String] = [], schema: LdapSchema?) {
        var hidden = Set((Self.alwaysHidden + extraHidden).map { $0.lowercased() })
        hidden.insert("2.5.4.35") // userPassword, whatever else is known
        if let schema {
            // Every name and the OID of a hidden type, and of any type
            // derived from one, until nothing more is added.
            var added = true
            while added {
                added = false
                for type in schema.attributeTypes {
                    let keys = type.names.map { $0.lowercased() } + [type.oid.lowercased()]
                    let isHidden = keys.contains(where: hidden.contains)
                        || type.superiorType.map { hidden.contains($0.lowercased()) } == true
                    if isHidden, !keys.allSatisfy(hidden.contains) {
                        hidden.formUnion(keys)
                        added = true
                    }
                }
            }
        }
        self.hidden = hidden
        knowsSchema = schema != nil
    }

    /// "member;range=0-1499" → "member".
    static func baseName(_ description: String) -> String {
        String(description.prefix { $0 != ";" }).lowercased()
    }

    static func isNumericOID(_ name: String) -> Bool {
        name.first?.isNumber == true && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    func isHidden(_ description: String) -> Bool {
        hidden.contains(Self.baseName(description))
    }

    /// What an attribute name an agent passed may look like: a name or a
    /// numeric OID, with options. Rules out anything that could be read as
    /// something else by the server.
    static func isWellFormed(_ description: String) -> Bool {
        guard let first = description.unicodeScalars.first, description.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.;"))
        return CharacterSet.alphanumerics.contains(first)
            && description.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    enum Violation: Error, CustomStringConvertible {
        case malformed(String)
        case hidden(String)
        case unresolvedOID(String)
        case anyAttributeMatch
        case unparenthesized

        var description: String {
            switch self {
            case let .malformed(name):
                return "\"\(name)\" isn't a valid attribute name."
            case let .hidden(name):
                return "\"\(name)\" is hidden from agents — LDAP Studio never shares passwords, keys or the attributes its user chose to hide, not even in a filter."
            case let .unresolvedOID(name):
                return "Use attribute names rather than OIDs (\"\(name)\"): this server's schema couldn't be read to check them."
            case .anyAttributeMatch:
                return "Extensible matches must name an attribute, e.g. (cn:caseExactMatch:=Alice)."
            case .unparenthesized:
                return "Wrap the filter in parentheses, e.g. (uid=alice)."
            }
        }
    }

    /// Throws unless an agent may ask for `description`.
    func check(_ description: String) throws {
        guard Self.isWellFormed(description) else { throw Violation.malformed(description) }
        if isHidden(description) { throw Violation.hidden(description) }
        if !knowsSchema, Self.isNumericOID(Self.baseName(description)) {
            throw Violation.unresolvedOID(description)
        }
    }

    /// Throws unless every attribute `filter` (RFC 4515) tests is one an
    /// agent may ask for. Errs on the side of refusing: anything that looks
    /// like an attribute name, even inside a value, is checked.
    func check(filter: String) throws {
        let scalars = Array(filter.unicodeScalars)
        guard scalars.first == "(", scalars.last == ")" else { throw Violation.unparenthesized }
        let structural = Set("&|!(".unicodeScalars)
        let terminators = Set("=~<>:()".unicodeScalars)
        for index in scalars.indices where scalars[index] == "(" {
            var cursor = index + 1
            guard cursor < scalars.count, !structural.contains(scalars[cursor]) else { continue }
            var name = String.UnicodeScalarView()
            while cursor < scalars.count, !terminators.contains(scalars[cursor]) {
                name.append(scalars[cursor])
                cursor += 1
            }
            // (:dn:2.5.13.5:=x) tests every attribute the rule applies to —
            // the hidden ones included.
            if name.isEmpty {
                if cursor < scalars.count, scalars[cursor] == ":" { throw Violation.anyAttributeMatch }
                continue
            }
            try check(String(name))
        }
    }
}
