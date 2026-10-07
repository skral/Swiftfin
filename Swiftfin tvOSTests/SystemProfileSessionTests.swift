//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import Foundation
import JellyfinAPI
import KeychainSwift
@testable import Swiftfin
import XCTest

/// Exercise the session policy without depending on simulator keychain signing.
private final class ProfileTestKeychain: KeychainSwift {
    private var values: [String: String] = [:]

    override func get(_ key: String) -> String? {
        values[key]
    }

    override func set(_ value: String, forKey key: String, withAccess access: KeychainSwiftAccessOptions? = nil) -> Bool {
        values[key] = value
        return true
    }

    override func delete(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}

@MainActor
final class SystemProfileSessionTests: XCTestCase {
    private var originalDefaults: [String: Any] = [:]
    private var user: UserState!
    private var manager: UserSessionManager!

    func testSystemProfilesUseDistinctPersistentJellyfinDeviceIDs() throws {
        let adultName = "profile-device-adult-\(UUID().uuidString)"
        let kidsName = "profile-device-kids-\(UUID().uuidString)"
        let adult = try XCTUnwrap(UserDefaults(suiteName: adultName))
        let kids = try XCTUnwrap(UserDefaults(suiteName: kidsName))
        defer {
            adult.removePersistentDomain(forName: adultName)
            kids.removePersistentDomain(forName: kidsName)
        }
        let adultID = SystemProfileDeviceIdentity.identifier(in: adult)
        let kidsID = SystemProfileDeviceIdentity.identifier(in: kids)
        XCTAssertNotEqual(adultID, kidsID, "Different Apple TV profiles must not share a Jellyfin server session")
        let reopenedAdult = try XCTUnwrap(UserDefaults(suiteName: adultName))
        XCTAssertEqual(adultID, SystemProfileDeviceIdentity.identifier(in: reopenedAdult))
        XCTAssertEqual(kidsID, SystemProfileDeviceIdentity.identifier(in: kids))
    }

    override func setUp() async throws {
        originalDefaults = UserDefaults.appSuite.persistentDomain(forName: "swiftfinApp") ?? [:]
        let keychain = ProfileTestKeychain()
        Container.shared.keychainService.register { keychain }
        let id = "profile-test-\(UUID().uuidString)"
        user = UserState(id: id, serverID: id, username: "Test")
        let url = URL(string: "http://127.0.0.1:1")!
        StoredValues[.Server.servers] = [ServerState(urls: [url], currentURL: url, name: "Test", id: id, userIDs: [id])]
        StoredValues[.User.users] = [user]
        user.accessToken = "test-token"
        user.accessPolicy = .none
        Defaults[.lastSignedInUserID] = .signedIn(userID: id)
        Defaults[.signOutOnClose] = false
        Defaults[.signOutOnBackground] = false
        UserDefaults.appSuite.removeObject(forKey: "tvosSystemProfileInitializedV1")
        manager = UserSessionManager()
    }

    override func tearDown() async throws {
        await manager.signOut(reason: .explicit)
        Container.shared.keychainService().delete("\(user.id)-accessToken")
        Container.shared.keychainService().delete("\(user.id)-pin")
        UserDefaults.userSuite(id: user.id).removePersistentDomain(forName: user.id)
        UserDefaults.appSuite.setPersistentDomain(originalDefaults, forName: "swiftfinApp")
        Container.shared.keychainService.reset()
        manager = nil
    }

    private func assertSignedOutSelection(file: StaticString = #filePath, line: UInt = #line) {
        guard case .signedOut = Defaults[.lastSignedInUserID] else {
            XCTFail("The remembered selection must be signed out", file: file, line: line)
            return
        }
    }

    func testLegacySelectionRequiresExplicitChoice() async {
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
        XCTAssertFalse(UserDefaults.appSuite.bool(forKey: "tvosSystemProfileInitializedV1"))
        XCTAssertEqual(StoredValues[.User.users], [user])
    }

    func testExplicitChoiceEnablesLaterRestoration() async throws {
        await manager.start()
        try await manager.signIn(userID: user.id)
        XCTAssertEqual(manager.currentSession?.user.id, user.id)
        XCTAssertTrue(UserDefaults.appSuite.bool(forKey: "tvosSystemProfileInitializedV1"))

        let nextLaunch = UserSessionManager()
        await nextLaunch.start()
        XCTAssertEqual(nextLaunch.currentSession?.user.id, user.id)
        await nextLaunch.signOut(reason: .explicit)
    }

    func testMissingTokenCannotCompleteSetup() async {
        Container.shared.keychainService().delete("\(user.id)-accessToken")
        Defaults[.lastSignedInUserID] = .signedOut
        do {
            try await manager.signIn(userID: user.id)
            XCTFail("A missing token must fail sign-in")
        } catch {}
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
        XCTAssertFalse(UserDefaults.appSuite.bool(forKey: "tvosSystemProfileInitializedV1"))
    }

    func testMissingStoredCredentialsReturnToSelection() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        Container.shared.keychainService().delete("\(user.id)-accessToken")
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testMissingServerDoesNotChooseAnotherAccount() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        StoredValues[.Server.servers] = []
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testMissingUserDoesNotChooseAnotherAccount() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        Defaults[.lastSignedInUserID] = .signedIn(userID: "deleted-user")
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testMissingRequiredPINReturnsToSelection() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        user.accessPolicy = .requirePin
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testSelectionRejectsMissingRequiredPIN() async {
        user.accessPolicy = .requirePin
        let model = SelectUserViewModel()
        var selected = false
        let subscription = model.events.sink { _ in selected = true }
        await model.signIn(user, pin: "1234")
        XCTAssertFalse(selected)
        XCTAssertNotNil(model.error)
        withExtendedLifetime(subscription) {}
    }

    func testExistingSignInRejectsMissingPINWithoutReplacingToken() async {
        user.accessPolicy = .requirePin
        let model = UserSignInViewModel(server: StoredValues[.Server.servers][0])
        let action = LocalUserAuthenticationAction { _, _ in
            PinEvaluatedUserAccessPolicy(pin: "1234", pinHint: nil)
        }
        await model.saveExisting(
            user: ((user, "replacement-token"), UserDto()),
            replaceForAccessToken: true,
            authenticationAction: (action, .requirePin, nil),
            evaluatedPolicyMap: .init(action: { $0 })
        )
        XCTAssertNotNil(model.error)
        XCTAssertEqual(Container.shared.keychainService().get("\(user.id)-accessToken"), "test-token")
        XCTAssertFalse(UserDefaults.appSuite.bool(forKey: "tvosSystemProfileInitializedV1"))
    }

    func testTVOSMigrationDoesNotImportLegacyCredentials() {
        let keychain = Container.shared.keychainService()
        SwiftfinStore.persistAccessTokenToKeychain(userID: user.id, accessToken: "legacy-adult-token")
        XCTAssertEqual(keychain.get("\(user.id)-accessToken"), "test-token")
        keychain.delete("\(user.id)-accessToken")
        SwiftfinStore.persistAccessTokenToKeychain(userID: user.id, accessToken: "legacy-adult-token")
        XCTAssertNil(keychain.get("\(user.id)-accessToken"))
    }

    func testRestoredProtectedUserAuthenticatesBeforePublication() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        user.accessPolicy = .requirePin
        user.pin = "1234"
        var authenticated = false
        let action = LocalUserAuthenticationAction { policy, _ in
            XCTAssertEqual(policy, .requirePin)
            XCTAssertNil(self.manager.currentSession)
            authenticated = true
            return PinEvaluatedUserAccessPolicy(pin: "1234", pinHint: nil)
        }
        await manager.start(authenticationAction: action)
        XCTAssertTrue(authenticated)
        XCTAssertEqual(manager.currentSession?.user.id, user.id)
    }

    func testFailedPINCannotRestoreOnForeground() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        user.accessPolicy = .requirePin
        user.pin = "1234"
        let action = LocalUserAuthenticationAction { _, _ in
            PinEvaluatedUserAccessPolicy(pin: "9876", pinHint: nil)
        }
        await manager.start(authenticationAction: action)
        await manager.appWillEnterForeground()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testExplicitSignOutStaysSignedOutOnNextLaunch() async throws {
        Defaults[.lastSignedInUserID] = .signedOut
        try await manager.signIn(userID: user.id)
        await manager.signOut(reason: .explicit)
        let nextLaunch = UserSessionManager()
        await nextLaunch.start()
        XCTAssertEqual(nextLaunch.state, .signedOut)
        XCTAssertTrue(UserDefaults.appSuite.bool(forKey: "tvosSystemProfileInitializedV1"))
    }

    func testSignOutOnCloseRemainsEffective() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        Defaults[.signOutOnClose] = true
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testBackgroundTimeoutAlsoAppliesAfterProcessRelaunch() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        Defaults[.signOutOnBackground] = true
        Defaults[.backgroundTimeStamp] = Date(timeIntervalSince1970: 0)
        Defaults[.backgroundSignOutInterval] = 100
        await manager.start()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        assertSignedOutSelection()
    }

    func testEmptyProfileCannotOpenAnotherProfilesDeepLink() async throws {
        StoredValues[.Server.servers] = []
        StoredValues[.User.users] = []
        await manager.start()
        let action = LocalUserAuthenticationAction { _, _ in
            XCTFail("An absent account must not reach authentication")
            return Empty()
        }
        let url = try XCTUnwrap(URL(string: "swiftfin://adult-server/adult-user/item/example"))
        await manager.handleOpenURL(url, authenticationAction: action)
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.currentSession)
        XCTAssertNil(manager.pendingDeepLink)
        XCTAssertFalse(UserDefaults.appSuite.bool(forKey: "tvosSystemProfileInitializedV1"))
    }

    func testForegroundBeforeStartupWaitsForAuthentication() async {
        UserDefaults.appSuite.set(true, forKey: "tvosSystemProfileInitializedV1")
        user.accessPolicy = .requirePin
        user.pin = "1234"
        await manager.appWillEnterForeground()
        XCTAssertEqual(manager.state, .initial)
        XCTAssertNil(manager.currentSession)
        let action = LocalUserAuthenticationAction { _, _ in
            PinEvaluatedUserAccessPolicy(pin: "1234", pinHint: nil)
        }
        await manager.start(authenticationAction: action)
        XCTAssertEqual(manager.currentSession?.user.id, user.id)
    }
}
