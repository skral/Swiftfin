//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Keep Jellyfin server sessions separate for each Apple TV system profile.
enum SystemProfileDeviceIdentity {
    private static let lock = NSLock()
    private static let key = "tvosSystemProfileDeviceIDV1"

    static func identifier(in defaults: UserDefaults) -> String {
        lock.withLock {
            if let stored = defaults.string(forKey: key), UUID(uuidString: stored) != nil {
                return stored
            }
            let identifier = UUID().uuidString
            defaults.set(identifier, forKey: key)
            return identifier
        }
    }
}
