//
//  UpdateChecker.swift
//  ldap-studio
//
//  Lightweight "there's a new version" check against the GitHub Releases
//  API. It does not self-install — it points the user at the release page.
//  Automatic check runs at most once a day on launch; the app-menu item
//  checks on demand.
//
//  Two channels: stable releases (vX.Y.Z) for everyone, and betas
//  (vX.Y.Z-beta.N, published as GitHub pre-releases) for whoever turns on
//  "Check for Beta Versions" — on by default in a beta build.
//

import AppKit
import Foundation

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private let repo = "mSarheed/ldap-studio"
    /// How stale the last automatic check may be before we look again.
    private let automaticInterval: TimeInterval = 60 * 60 * 24

    private enum Key {
        static let lastCheck = "updateCheck.lastCheck"
        static let skippedVersion = "updateCheck.skippedVersion"
        static let includesBetas = "updateCheck.includesBetas"
    }

    /// The `@AppStorage` key behind the "Check for Beta Versions" menu item.
    static let includesBetasKey = Key.includesBetas

    /// Until the user picks, a beta build follows betas — whoever installed
    /// one asked for them — and a stable build doesn't.
    static var includesBetasByDefault: Bool {
        AppVersion(appVersion)?.isBeta ?? false
    }

    static var includesBetas: Bool {
        UserDefaults.standard.object(forKey: Key.includesBetas) as? Bool ?? includesBetasByDefault
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft
        }
    }

    // MARK: - Entry points

    /// Called once on launch — silent unless there's a newer version, and
    /// throttled to `automaticInterval`.
    func checkOnLaunch() async {
        if let last = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date,
           Date().timeIntervalSince(last) < automaticInterval {
            return
        }
        await check(userInitiated: false)
    }

    /// `userInitiated` also reports "you're up to date" and any error.
    func check(userInitiated: Bool) async {
        do {
            let release = try await fetchNewest(includingBetas: Self.includesBetas)
            UserDefaults.standard.set(Date(), forKey: Key.lastCheck)

            let current = Self.appVersion
            // An unparseable local version (a hand-made build) is behind everything.
            guard let release, let newest = AppVersion(release.tagName),
                  newest > AppVersion(current) ?? AppVersion.zero else {
                if userInitiated { await alertUpToDate(current) }
                return
            }
            let latest = newest.description
            if !userInitiated,
               UserDefaults.standard.string(forKey: Key.skippedVersion) == latest {
                return
            }
            await alertUpdate(release, latest: latest, current: current)
        } catch {
            if userInitiated { await alertError(error) }
        }
    }

    /// Present as a window sheet when there's a window to host it — the
    /// sheet runs in the normal run loop, so precise trackpad scrolling in
    /// the release-notes view stays smooth (`runModal()` spins a modal loop
    /// that makes it jump). Falls back to app-modal at launch when no
    /// window is up yet.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        let host = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        guard let host else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: host) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Network

    /// The newest release on the channel, or nil when it has none yet.
    /// `releases/latest` is GitHub's newest non-pre-release; betas need the
    /// list, newest first, from which the highest version wins.
    private func fetchNewest(includingBetas: Bool) async throws -> Release? {
        if includingBetas {
            let releases: [Release]? = try await get("releases?per_page=30")
            return releases?
                .filter { $0.draft != true }
                .compactMap { release in AppVersion(release.tagName).map { (release, $0) } }
                .max { $0.1 < $1.1 }?.0
        }
        return try await get("releases/latest")
    }

    /// GETs `repos/<repo>/<path>`; nil on 404 (no releases yet).
    private func get<T: Decodable>(_ path: String) async throws -> T? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ldap-studio-app", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Versions

    static var appVersion: String {
        // Debug override so the update prompt can be exercised while
        // already on the latest release:
        //   defaults write app.ldap-studio updateCheck.fakeCurrentVersion 1.0.0
        // (delete the key to restore normal behaviour).
        if let fake = UserDefaults.standard.string(forKey: "updateCheck.fakeCurrentVersion"),
           !fake.isEmpty {
            return fake
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A release version as tagged: "1.4.0", or "1.4.0-beta.2" for a beta.
    /// A stable release is newer than every beta of the same version, so a
    /// beta user is offered 1.4.0 once it replaces 1.4.0-beta.2.
    struct AppVersion: Comparable, CustomStringConvertible {
        static let zero = AppVersion(release: [0, 0, 0], beta: nil)

        let release: [Int]
        /// nil for a stable release.
        let beta: Int?

        var isBeta: Bool { beta != nil }

        /// "v1.4.0", "1.4.0", "1.4" or "1.4.0-beta.2"; nil for anything else.
        init?(_ string: String) {
            var s = Substring(string.trimmingCharacters(in: .whitespaces))
            if s.first == "v" || s.first == "V" { s = s.dropFirst() }
            let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...3).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            var beta: Int?
            if parts.count == 2 {
                guard parts[1].hasPrefix("beta."), let n = Int(parts[1].dropFirst(5)), n > 0 else { return nil }
                beta = n
            }
            self.init(release: numbers.compactMap { $0 } + Array(repeating: 0, count: 3 - numbers.count), beta: beta)
        }

        private init(release: [Int], beta: Int?) {
            self.release = release
            self.beta = beta
        }

        var description: String {
            release.map(String.init).joined(separator: ".") + (beta.map { "-beta.\($0)" } ?? "")
        }

        static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
            if lhs.release != rhs.release { return lhs.release.lexicographicallyPrecedes(rhs.release) }
            switch (lhs.beta, rhs.beta) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            default: return false
            }
        }
    }

    // MARK: - Alerts

    private func alertUpdate(_ release: Release, latest: String, current: String) async {
        let alert = NSAlert()
        alert.messageText = "LDAP Studio \(latest) is available"
        alert.informativeText = "You have \(current)."

        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            alert.accessoryView = Self.notesView(notes)
        }

        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")

        switch await present(alert) {
        case .alertFirstButtonReturn:
            if let url = URL(string: release.htmlURL) { NSWorkspace.shared.open(url) }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(latest, forKey: Key.skippedVersion)
        default:
            break
        }
    }

    /// Release notes rendered from GitHub Markdown into a scrollable,
    /// selectable text view with clickable links.
    private static func notesView(_ markdown: String) -> NSScrollView {
        let width: CGFloat = 460
        let height: CGFloat = 220

        // `scrollableTextView()` wires the clip/document/resize masks and
        // container tracking the way AppKit expects — hand-building it was
        // what made the scroll jump.
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.wantsLayer = true
        scroll.contentView.drawsBackground = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.textStorage?.setAttributedString(rendered(markdown))
        return scroll
    }

    /// GitHub release bodies are block Markdown, but `AttributedString`'s
    /// bridge to `NSAttributedString` drops the line breaks between blocks.
    /// So render one line at a time: strip a heading/bullet prefix, parse
    /// the rest as inline Markdown (links, bold, italic, code), and rejoin.
    private static func rendered(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let out = NSMutableAttributedString()

        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            var text = trimmed
            var bullet: String?
            var isHeading = false

            if let hashes = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                text = String(trimmed[hashes.upperBound...])
                isHeading = true
            } else if trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil {
                text = String(trimmed.dropFirst(2))
                bullet = "•  "
            }

            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            options.failurePolicy = .returnPartiallyParsedIfPossible
            let inline = (try? AttributedString(markdown: text, options: options))
                ?? AttributedString(text)
            let piece = NSMutableAttributedString(inline)
            let whole = NSRange(location: 0, length: piece.length)

            let lineFont = isHeading
                ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
                : base
            piece.addAttribute(.font, value: lineFont, range: whole)
            piece.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)

            // Resolve bold / italic / code that the inline parse recorded as
            // presentation intents rather than fonts.
            piece.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                let intent: InlinePresentationIntent
                if let direct = value as? InlinePresentationIntent {
                    intent = direct
                } else if let raw = value as? UInt {
                    intent = InlinePresentationIntent(rawValue: raw)
                } else if let raw = value as? Int {
                    intent = InlinePresentationIntent(rawValue: UInt(raw))
                } else {
                    return
                }
                if intent.contains(.code) {
                    piece.addAttribute(.font,
                                       value: NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular),
                                       range: range)
                    return
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = lineFont.fontDescriptor.withSymbolicTraits(traits)
                    piece.addAttribute(.font,
                                       value: NSFont(descriptor: descriptor, size: lineFont.pointSize) ?? lineFont,
                                       range: range)
                }
            }

            if let bullet {
                out.append(NSAttributedString(string: bullet, attributes: [
                    .font: base, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            out.append(piece)
            if index < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        paragraph.lineSpacing = 2
        out.addAttribute(.paragraphStyle, value: paragraph,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    private func alertUpToDate(_ current: String) async {
        let alert = NSAlert()
        alert.messageText = "You’re up to date"
        alert.informativeText = "LDAP Studio \(current) is the latest version."
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    private func alertError(_ error: Error) async {
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }
}
