//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreStore
import FactoryKit
import Foundation
import Nuke
@testable import Swiftfin
import XCTest

/// Opt-in physical-device characterization, never a simulator isolation proof.
/// Set SWIFTFIN_PROFILE_PROBE_ACTION to seed or read, and
/// SWIFTFIN_PROFILE_PROBE_VALUE to a non-secret label (adult or kids).
/// On a clean installation: seed adult, switch to Kids and seed kids, then
/// switch back and read adult, then read kids. Seeding asserts every sentinel
/// is absent before writing anything, so shared storage fails instead of being
/// overwritten. For upgrade testing, seed the unentitled build first, install
/// this build over it, and record which profile owns those original sentinels.
/// Record process termination/relaunch separately while switching in the app;
/// restarting an XCTest runner does not itself prove that lifecycle behavior.
final class SystemProfileStorageTests: XCTestCase {
    func testPhysicalProfileStorage() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System-profile isolation requires a physical Apple TV")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let action = environment["SWIFTFIN_PROFILE_PROBE_ACTION"],
              let value = environment["SWIFTFIN_PROFILE_PROBE_VALUE"]
        else {
            throw XCTSkip("Set the profile probe action and non-secret value explicitly")
        }
        guard ["seed", "read"].contains(action), ["adult", "kids"].contains(value) else {
            XCTFail("Use seed/read and adult/kids")
            return
        }

        let key = "swiftfin-system-profile-storage-probe-v1"
        let suites = [UserDefaults.appSuite, UserDefaults.userSuite(id: key)]
        let keychain = Container.shared.keychainService()
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let sqlite = SQLiteStore(fileName: "Swiftfin.sqlite").fileURL
        let posterCache = try XCTUnwrap(DataCache.Swiftfin.posters).path
        let localCache = try XCTUnwrap(DataCache.Swiftfin.local).path
        let roots = [documents, caches, sqlite.deletingLastPathComponent(), posterCache, localCache]
        let files = roots.map { $0.appendingPathComponent(key) }

        if action == "seed" {
            // Check all domains before changing any of them. Keep these values
            // across test runs to observe actual persistence and separation.
            for suite in suites {
                XCTAssertNil(suite.object(forKey: key), "Defaults exposed an existing profile sentinel")
            }
            XCTAssertNil(keychain.get(key), "Ordinary keychain exposed an existing profile sentinel")
            for file in files {
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "File storage exposed an existing sentinel")
            }
            guard suites.allSatisfy({ $0.object(forKey: key) == nil }),
                  keychain.get(key) == nil,
                  files.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) })
            else { return }

            for suite in suites {
                suite.set(value, forKey: key)
            }
            XCTAssertTrue(keychain.set(value, forKey: key))
            for file in files {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(value.utf8).write(to: file, options: .atomic)
            }
        }

        for suite in suites {
            XCTAssertEqual(suite.string(forKey: key), value)
        }
        XCTAssertEqual(keychain.get(key), value)
        for file in files {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), value)
        }

        // Only container locations and a process ID are attached, never stored
        // catalogs, credentials, PINs, or personal account identifiers.
        let locations = XCTAttachment(string: "PID: \(ProcessInfo.processInfo.processIdentifier)\nSQLite: \(sqlite.path)\n" + roots
                .map(\.path).joined(separator: "\n"))
        locations.name = "Profile storage locations"
        locations.lifetime = .keepAlways
        add(locations)
        #endif
    }
}
