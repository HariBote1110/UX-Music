import Foundation

/// Generates and persists the TV remote-command receiver's own **control token** — deliberately
/// independent of the host pairing token stored in `TVServerConfigStore`/`ServerConfig.token`.
///
/// Security fix (`progress/tvos-connect.md` 2026-08-12 追記): previously `TVRemoteControlServer`
/// authenticated with, and broadcast in its mDNS TXT record, the SAME token the TV uses against
/// the Host — leaking a credential that grants access to the Host's entire `/v1/remote/*` library
/// API to anyone on the LAN. This store hands out a value the receiver mints for itself, which
/// only ever grants control of this TV's own playback (comparable exposure to the existing open
/// pairing endpoints — an accepted risk per `progress/tvos-pairing.md`).
///
/// `defaults` is injectable so tests never touch the real `UserDefaults.standard` suite, matching
/// `TVServerConfigStore`'s pattern. Storage key is distinct from `AppConstants.serverConfigKey` so
/// the two tokens can never collide or be confused.
struct TVControlTokenStore {
    private static let storageKey = "tv_control_token"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the persisted control token, minting and persisting a fresh random one on first
    /// use. Stable across app launches (the mDNS TXT record and every `Authorization` check must
    /// agree on the same value), but never derived from or equal to the host pairing token.
    func loadOrCreate() -> String {
        if let existing = defaults.string(forKey: Self.storageKey), !existing.isEmpty {
            return existing
        }
        let generated = Self.generateToken()
        defaults.set(generated, forKey: Self.storageKey)
        return generated
    }

    /// 32 cryptographically-random bytes, hex-encoded (64 characters) — matches the entropy of a
    /// typical bearer token without needing extra dependencies beyond `SystemRandomNumberGenerator`.
    private static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
