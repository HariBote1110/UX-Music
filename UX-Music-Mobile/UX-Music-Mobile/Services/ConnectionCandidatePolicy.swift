import Foundation

/// Decides which host(s) `AppModel.withFailover` should try, given the user's chosen connection
/// mode (`ServerConfig.preferredHost`). Kept as a pure function so the "auto vs fixed" decision can
/// be unit-tested without any networking.
enum ConnectionCandidatePolicy {
    /// - `preferredHost` set (non-empty after trimming): "fixed" mode — only that host is tried, so
    ///   a failure surfaces as an error instead of silently failing over to another NIC/Tailscale
    ///   address.
    /// - `preferredHost` nil/empty: "auto" mode (current behaviour) — `primaryHost` first, then each
    ///   `fallbackHosts` entry in order.
    static func hostsToTry(
        primaryHost: String,
        fallbackHosts: [String],
        preferredHost: String?
    ) -> [String] {
        if let preferred = preferredHost?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty {
            return [preferred]
        }
        return [primaryHost] + fallbackHosts
    }
}

extension ServerConfig {
    /// Every host known for this desktop — `host` plus `fallbackHosts` — de-duplicated
    /// (case-insensitive) while preserving first-seen order. Used by Settings to list every
    /// candidate the user can pin as `preferredHost`.
    var allKnownHosts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for candidate in [host] + fallbackHosts {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    /// Whether `hostString` looks like a Tailscale address (CGNAT range `100.64.0.0/10`, which
    /// Tailscale assigns its MagicDNS IPs from). Best-effort — used only for a UI badge, not for
    /// any connection decision.
    static func isTailscaleLikeHost(_ hostString: String) -> Bool {
        let parts = hostString.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 100 && (64...127).contains(second)
    }
}
