import Foundation

/// The plugin's state inside the host's `fullState` dictionary (Audio Unit design §2, "State").
///
/// `AUAudioUnit.fullState` is a dictionary the superclass fills with the component's identity
/// and its parameter values (the keys an AUv2 `ClassInfo` has: `type`, `subtype`, `manufacturer`,
/// `version`, `data`, `name`…), and Apple's header asks a subclass that adds state to add keys to
/// the superclass's dictionary rather than replace it. So the getter merges the plugin's bytes in
/// under one key of its own, and the setter hands the whole dictionary to the superclass and takes
/// the bytes out.
///
/// Free of AU types (design §3): the unit's override is two lines over these.
nonisolated enum PluginFullState {
    /// The key the plugin's ``PluginState`` bytes are stored under; reverse-DNS, so it can never
    /// be one of Apple's.
    static let key = "com.quassum.neuralsheet.state"

    /// The superclass's dictionary with `blob` added under ``key``, every other key as it was. A
    /// nil `blob` leaves the dictionary without the key.
    static func merging(_ blob: Data?, into base: [String: Any]?) -> [String: Any] {
        var merged = base ?? [:]
        merged[key] = blob
        return merged
    }

    /// The plugin's bytes in `state`, nil when it has none (a session saved before the plugin
    /// kept state, or a preset made by the host from parameters alone).
    static func blob(in state: [String: Any]?) -> Data? {
        state?[key] as? Data
    }
}
