//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Get
import JellyfinAPI
import UIKit

extension JellyfinClient.Configuration {

    static func swiftfinConfiguration(
        url: URL,
        accessToken: String? = nil
    ) -> Self {

        let client = "Swiftfin \(UIDevice.platform)"
        let deviceName = UIDevice.current.name
            .folding(options: .diacriticInsensitive, locale: .current)
            .unicodeScalars
            .filter { CharacterSet.urlQueryAllowed.contains($0) }
            .description
        #if os(tvOS)
        // Jellyfin groups active sessions by client and device ID. A physical
        // vendor ID would merge accounts from otherwise isolated TV profiles.
        let deviceID = "\(UIDevice.platform)_\(SystemProfileDeviceIdentity.identifier(in: .appSuite))"
        #else
        let deviceID = "\(UIDevice.platform)_\(UIDevice.vendorUUIDString)"
        #endif
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.1"

        return .init(
            url: url,
            accessToken: accessToken,
            client: client,
            deviceName: deviceName,
            deviceID: deviceID,
            version: version
        )
    }
}
