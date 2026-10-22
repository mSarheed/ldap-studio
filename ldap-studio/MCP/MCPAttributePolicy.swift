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
//  Names are checked against the server's schema, so an alias or OID of a
//  hidden attribute is caught too. Without a schema to check against,
//  nothing an agent names is accepted except objectClass: the policy
//  fails closed.
//

import Foundation

nonisolated struct MCPAttributePolicy: Sendable {
    /// Secrets on the common directory servers.
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
        // OpenLDAP configuration (cn=config): root and replication/proxy
        // bind credentials
        "olcRootPW", "olcSyncrepl", "olcDbACLPasswd", "olcDbACLBind", "olcDbIDAssertBind", "olcDbPass",
        // 389 Directory Server
        "nsslapd-rootpw", "nsds5ReplicaCredentials", "nsDS5ReplicaBootstrapCredentials",
        "nsMultiplexorCredentials", "nsSymmetricKey",
        // Samba, Kerberos, FreeIPA, OATH, RADIUS
        "sambaNTPassword", "sambaLMPassword", "sambaPasswordHistory",
        "krbPrincipalKey", "krbMKey", "krb5Key", "ipaNTHash", "ipatokenOTPkey",
        "oathSecret", "radiusTunnelPassword",
    ]

    /// Lowercased names and OIDs of the hidden attributes and of every type
    /// derived from one.
    private let hidden: Set<String>
    /// Their supertypes: a filter on `name` also tests `sn`, so if `sn` is
    /// hidden, `name` can't be filtered on either.
    private let hiddenSupertypes: Set<String>
    /// Every attribute name and OID the schema defines, lowercased.
    private let known: Set<String>
    /// Active Directory's anr, by name and OID: it searches whatever set of
    /// attributes the server is configured with.
    private let ambiguousNameResolution: Set<String>
    /// A hidden attribute was given as an OID the policy can't put a name
    /// to, so an attribute it doesn't know might be that one.
    private let hasUnresolvedHiddenOIDs: Bool

    /// OIDs of the attributes named without a schema to resolve them —
    /// objectClass, which is always allowed, and userPassword.
    private static let wellKnownOIDs = ["2.5.4.0": "objectclass", "2.5.4.35": "userpassword"]
    /// The server's schema was read (and isn't empty), so names can be
    /// resolved. Without it, nothing but objectClass is accepted.
    let knowsSchema: Bool

    init(extraHidden: [String] = [], schema: LdapSchema?) {
        // "mail;lang-en" hides all of mail: options don't make a separate
        // attribute, and matching ignores them.
        var hidden = Set((Self.alwaysHidden + extraHidden).map(Self.baseName))
        for (oid, name) in Self.wellKnownOIDs where hidden.contains(oid) || hidden.contains(name) {
            hidden.formUnion([oid, name])
        }
        var supertypes = Set<String>()
        var known = Set<String>()
        var anr: Set<String> = ["anr"]
        let types = schema?.attributeTypes ?? []
        func keys(_ type: SchemaAttributeType) -> [String] {
            type.names.map { $0.lowercased() } + [type.oid.lowercased()]
        }
        if !types.isEmpty {
            var byKey: [String: SchemaAttributeType] = [:]
            for type in types {
                for key in keys(type) { byKey[key] = type }
            }
            known = Set(byKey.keys)
            anr.formUnion(byKey["anr"].map(keys) ?? [])
            // Every name and the OID of a hidden type, and of any type
            // derived from one, until nothing more is added.
            var added = true
            while added {
                added = false
                for type in types {
                    let isHidden = keys(type).contains(where: hidden.contains)
                        || type.superiorType.map { hidden.contains($0.lowercased()) } == true
                    if isHidden, !keys(type).allSatisfy(hidden.contains) {
                        hidden.formUnion(keys(type))
                        added = true
                    }
                }
            }
            for type in types where keys(type).contains(where: hidden.contains) {
                var superior = type.superiorType?.lowercased()
                var depth = 0
                while let name = superior, let parent = byKey[name], depth < 32 {
                    supertypes.formUnion(keys(parent))
                    superior = parent.superiorType?.lowercased()
                    depth += 1
                }
            }
        }
        self.hidden = hidden
        hasUnresolvedHiddenOIDs = hidden.contains { Self.isNumericOID($0) && !known.contains($0) && Self.wellKnownOIDs[$0] == nil }
        hiddenSupertypes = supertypes.subtracting(hidden)
        self.known = known
        ambiguousNameResolution = anr
        knowsSchema = !types.isEmpty
    }

    /// "member;range=0-1499" → "member".
    static func baseName(_ description: String) -> String {
        String(description.prefix { $0 != ";" }).lowercased()
    }

    static func isNumericOID(_ name: String) -> Bool {
        name.first?.isNumber == true && name.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }

    func isHidden(_ description: String) -> Bool {
        hidden.contains(Self.baseName(description))
    }

    /// Whether a returned attribute may be shown. Only ones the schema
    /// resolves (objectClass aside): an attribute it doesn't know could be
    /// an alias or subtype of a hidden one, so without a schema nothing but
    /// objectClass is shown.
    func isShown(_ description: String) -> Bool {
        let name = Self.baseName(description)
        return !hidden.contains(name) && (name == "objectclass" || known.contains(name))
    }

    /// Looser, for the root DSE, which describes the server rather than
    /// holding directory data, and on Active Directory is mostly outside
    /// the schema: a name the schema doesn't know is shown too — unless a
    /// hidden attribute was given as an OID that couldn't be resolved, in
    /// which case it might be that one.
    func isShownInRootDSE(_ description: String) -> Bool {
        let name = Self.baseName(description)
        return !hidden.contains(name) && (known.contains(name) || !hasUnresolvedHiddenOIDs)
    }

    /// What an attribute name an agent passed may look like: a name or a
    /// numeric OID, with options. Rules out anything that could be read as
    /// something else by the server.
    static func isWellFormed(_ description: String) -> Bool {
        guard let first = description.unicodeScalars.first, description.utf8.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.;"))
        return CharacterSet.alphanumerics.contains(first)
            && description.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    enum Violation: Error, CustomStringConvertible {
        case malformed(String)
        case hidden(String)
        case hiddenSubtype(String)
        case noSchema(String)
        case unknown(String)
        case ambiguousNameResolution
        case anyAttributeMatch
        case unparenthesized

        var description: String {
            switch self {
            case let .malformed(name):
                return "\"\(name)\" isn't a valid attribute name."
            case let .hidden(name):
                return "\"\(name)\" is hidden from agents — LDAP Studio never shares passwords, keys or the attributes its user chose to hide, not even in a filter."
            case let .hiddenSubtype(name):
                return "\"\(name)\" can't be used in a filter: it also matches attributes hidden from agents, which are its subtypes. Filter on a more specific attribute."
            case let .noSchema(name):
                return "LDAP Studio couldn't read this server's schema, so it can't check \"\(name)\" against the attributes it hides from agents. Without the schema, filters can only test objectClass, and entries come back with all the attributes they may show."
            case let .unknown(name):
                return "This server's schema has no attribute \"\(name)\". get_schema lists the ones it has."
            case .ambiguousNameResolution:
                return "Ambiguous name resolution (anr) isn't allowed: it searches a server-defined set of attributes that may include hidden ones. Name the attributes, e.g. (|(cn=Ann*)(sAMAccountName=ann*))."
            case .anyAttributeMatch:
                return "Extensible matches must name an attribute, e.g. (cn:caseExactMatch:=Alice)."
            case .unparenthesized:
                return "Wrap the filter in parentheses, e.g. (uid=alice)."
            }
        }
    }

    /// Throws unless an agent may ask for `description` — as an attribute
    /// to return, or, with `inFilter`, as one a filter tests.
    func check(_ description: String, inFilter: Bool = false) throws {
        guard Self.isWellFormed(description) else { throw Violation.malformed(description) }
        let name = Self.baseName(description)
        if hidden.contains(name) { throw Violation.hidden(description) }
        if inFilter, hiddenSupertypes.contains(name) { throw Violation.hiddenSubtype(description) }
        if inFilter, ambiguousNameResolution.contains(name) { throw Violation.ambiguousNameResolution }
        guard knowsSchema else {
            if name == "objectclass" { return }
            throw Violation.noSchema(description)
        }
        guard known.contains(name) else { throw Violation.unknown(description) }
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
            try check(String(name), inFilter: true)
        }
    }
}
