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
import Logging

extension Container {

    var userSessionManager: Factory<UserSessionManager> {
        self { UserSessionManager() }
            .singleton
    }

    var currentUserSession: Factory<UserSession?> {
        self { self.userSessionManager().currentSession }
            .cached
    }
}

final class UserSessionManager: ObservableObject {

    enum State: Equatable {
        case initial
        case signedOut
        case signedIn
    }

    enum SignOutReason {
        case backgroundTimeout
        case explicit
    }

    enum AuthenticationError: Error {
        case missingAuthenticationAction
    }

    @Injected(\.keychainService)
    private var keychain: KeychainSwift

    @Published
    private(set) var state: State = .initial

    @Published
    private(set) var currentSession: UserSession?

    @Published
    private(set) var pendingDeepLink: DeepLink?

    let routePublisher = PassthroughSubject<NavigationRoute, Never>()

    var cancellables = Set<AnyCancellable>()

    let logger = Logger.swiftfin()

    private(set) var mediaPlayerManager: MediaPlayerManager?

    @MainActor
    var hasActivePlayback: Bool {
        guard let mediaPlayerManager else { return false }
        return mediaPlayerManager.state != .stopped
    }

    init() {
        setupObservations()
    }

    @MainActor
    func start(authenticationAction: LocalUserAuthenticationAction? = nil) async {
        guard state == .initial else { return }

        do {
            if Defaults[.signOutOnClose] {
                Defaults[.lastSignedInUserID] = .signedOut
            }
            #if os(tvOS)
            // A system-profile switch relaunches the process, so the existing
            // background timeout must also be honored before restoration.
            if Defaults[.signOutOnBackground],
               Date.now.timeIntervalSince(Defaults[.backgroundTimeStamp]) > Defaults[.backgroundSignOutInterval]
            {
                Defaults[.lastSignedInUserID] = .signedOut
            }
            #endif

            let session = try resolveStoredSession()
            #if os(tvOS)
            if let session, session.user.accessPolicy != .none {
                guard let authenticationAction else {
                    throw AuthenticationError.missingAuthenticationAction
                }
                try await authenticate(user: session.user, authenticationAction: authenticationAction)
            }
            #endif
            try Task.checkCancellation()
            await updateCurrentSession(with: session)
        } catch {
            logger.error(
                "Unable to restore launch session",
                metadata: ["error": .string(error.localizedDescription)]
            )

            Defaults[.lastSignedInUserID] = .signedOut
            await updateCurrentSession(with: nil)
        }
    }

    @MainActor
    private func refreshCurrentSession() async {
        do {
            let session = try resolveStoredSession()
            #if os(tvOS)
            // Foreground refresh may retain an authenticated session, but must
            // never bypass startup authentication for a different account.
            if let session, session.user.accessPolicy != .none,
               currentSession?.user.id != session.user.id || currentSession?.server.id != session.server.id
            {
                throw AuthenticationError.missingAuthenticationAction
            }
            #endif
            await updateCurrentSession(with: session)
        } catch {
            logger.error(
                "Unable to refresh current user session",
                metadata: ["error": .string(error.localizedDescription)]
            )
            Defaults[.lastSignedInUserID] = .signedOut
            await updateCurrentSession(with: nil)
        }
    }

    @MainActor
    func signIn(userID: String) async throws {
        // Existing selection/sign-in flows have already authenticated locally.
        // Validate credentials before persisting the current profile's choice.
        let session = try storedSession(userID: userID)
        try Task.checkCancellation()
        Defaults[.lastSignedInUserID] = .signedIn(userID: userID)
        await updateCurrentSession(with: session)
        #if os(tvOS)
        Defaults[.tvosSystemProfileInitializedV1] = true
        #endif

        Task {
            await refreshServerInformationIfNeeded(reason: .explicitSignIn)
        }
    }

    @MainActor
    func signOut(reason: SignOutReason) async {
        Defaults[.lastSignedInUserID] = .signedOut
        guard currentSession != nil else { return }
        await refreshCurrentSession()

        logger.info(
            "Signed out current user",
            metadata: ["reason": .string(String(describing: reason))]
        )
    }

    @MainActor
    private func stopActivePlayback() async {
        await mediaPlayerManager?.stop()
        self.mediaPlayerManager = nil
    }

    @MainActor
    func scheduleServerConnectionResolution() {
        currentSession?.serverConnectionManager.scheduleConnectionResolution()
    }

    @MainActor
    func handleOpenURL(
        _ url: URL,
        authenticationAction: LocalUserAuthenticationAction
    ) async {
        guard let deepLink = DeepLink(url) else { return }

        do {
            let deepLinkSession = try session(for: deepLink)
            let currentSession = currentSession
            let isSameUserSession = currentSession?.server.id == deepLinkSession.server.id && currentSession?.user.id == deepLinkSession
                .user.id

            if !isSameUserSession {
                try await authenticate(
                    user: deepLinkSession.user,
                    authenticationAction: authenticationAction
                )

                if hasActivePlayback {
                    await stopActivePlayback()
                }

                try await signIn(userID: deepLinkSession.user.id)
            }

            pendingDeepLink = deepLink
        } catch {
            logger.error(
                "Failed to process deep link",
                metadata: ["error": .string(error.localizedDescription)]
            )
        }
    }

    @MainActor
    func consumePendingDeepLink() -> DeepLink? {
        defer {
            pendingDeepLink = nil
        }

        return pendingDeepLink
    }

    @MainActor
    func appDidEnterBackground() {
        Defaults[.backgroundTimeStamp] = Date.now
    }

    @MainActor
    func appWillEnterForeground() async {
        #if os(tvOS)
        // Startup owns the first-use and local-authentication gates.
        guard state != .initial else { return }
        #endif
        await refreshCurrentSession()

        Task {
            await refreshServerInformationIfNeeded(reason: .stale)
        }

        guard currentSession != nil else { return }
        guard Defaults[.signOutOnBackground] else { return }
        guard !hasActivePlayback else { return }

        let backgroundedInterval = Date.now.timeIntervalSince(Defaults[.backgroundTimeStamp])
        if backgroundedInterval > Defaults[.backgroundSignOutInterval] {
            await signOut(reason: .backgroundTimeout)
        }
    }

    private enum ServerInformationRefreshReason {
        case explicitSignIn
        case stale
    }

    private func session(for deepLink: DeepLink) throws -> (server: ServerState, user: UserState) {
        guard let server = StoredValues[.Server.servers].first(where: { $0.id == deepLink.serverID }) else {
            throw DeepLinkError.missingServer(deepLink.serverID)
        }

        guard let user = StoredValues[.User.users].first(where: { $0.id == deepLink.userID && $0.serverID == server.id }) else {
            throw DeepLinkError.missingUser(deepLink.userID)
        }

        return (server, user)
    }

    private func authenticate(
        user: UserState,
        authenticationAction: LocalUserAuthenticationAction
    ) async throws {
        guard user.accessPolicy != .none else { return }

        let evaluatedPolicy = try await authenticationAction(
            policy: user.accessPolicy,
            reason: user.accessPolicy.authenticateReason(user: user)
        )

        if user.accessPolicy == .requirePin {
            guard let pinPolicy = evaluatedPolicy as? PinEvaluatedUserAccessPolicy,
                  let storedPin = keychain.get("\(user.id)-pin"), storedPin.isNotEmpty
            else {
                throw UserSessionError.missingStoredCredentials(userID: user.id)
            }
            guard pinPolicy.pin == storedPin else {
                throw ErrorMessage(L10n.incorrectPinForUser(user.username))
            }
        }
    }

    @MainActor
    private func refreshServerInformationIfNeeded(reason: ServerInformationRefreshReason) async {
        guard let currentSession else { return }

        switch reason {
        case .explicitSignIn:
            break
        case .stale:
            guard Defaults[.lastServerInformationRefreshDate].isStale(with: .hours(24)) else { return }
        }

        do {
            try await currentSession.server.updateServerInfo()
            try await currentSession.user.updateUserData(server: currentSession.server)

            Defaults[.lastServerInformationRefreshDate] = Date.now
        } catch {
            logger.error(
                "Unable to refresh server and user information",
                metadata: ["error": .string(error.localizedDescription)]
            )
        }
    }

    private func setupObservations() {
        Notifications[.applicationDidEnterBackground]
            .publisher
            .sink { [weak self] in
                Task { @MainActor in
                    self?.appDidEnterBackground()
                }
            }
            .store(in: &cancellables)

        Notifications[.applicationWillEnterForeground]
            .publisher
            .sink { [weak self] in
                Task { @MainActor in
                    await self?.appWillEnterForeground()
                }
            }
            .store(in: &cancellables)

        Container.shared.mediaPlayerManagerPublisher()
            .sink { [weak self] manager in
                Task { @MainActor in
                    self?.mediaPlayerManager = manager
                }
            }
            .store(in: &cancellables)

        observeSocketCommands()
    }

    @MainActor
    private func updateCurrentSession(with newSession: UserSession?) async {
        let previousSession = currentSession

        previousSession?.willStop()
        await newSession?.willStart()

        currentSession = newSession
        Container.shared.currentUserSession.reset()

        if previousSession?.server.id != newSession?.server.id || previousSession?.user.id != newSession?.user.id {
            Container.shared.mediaPlayerManager.reset()
        }

        if newSession == nil {
            state = .signedOut
        } else {
            state = .signedIn
        }

        newSession?.didStart()
    }

    private func resolveStoredSession() throws -> UserSession? {
        #if os(tvOS)
        guard Defaults[.tvosSystemProfileInitializedV1] else {
            Defaults[.lastSignedInUserID] = .signedOut
            return nil
        }
        #endif
        guard case let .signedIn(userID) = Defaults[.lastSignedInUserID] else { return nil }
        return try storedSession(userID: userID)
    }

    private func storedSession(userID: String) throws -> UserSession {
        guard let user = StoredValues[.User.users].first(where: { $0.id == userID }) else {
            Defaults[.lastSignedInUserID] = .signedOut
            throw UserSessionError.invalidStoredSession(userID: userID)
        }

        guard let server = StoredValues[.Server.servers].first(where: { $0.id == user.serverID }) else {
            Defaults[.lastSignedInUserID] = .signedOut
            throw UserSessionError.invalidStoredSession(userID: userID)
        }

        guard let token = keychain.get("\(user.id)-accessToken"), token.isNotEmpty else {
            throw UserSessionError.missingStoredCredentials(userID: user.id)
        }
        if user.accessPolicy == .requirePin {
            guard let pin = keychain.get("\(user.id)-pin"), pin.isNotEmpty else {
                throw UserSessionError.missingStoredCredentials(userID: user.id)
            }
        }

        let session = UserSession(server: server, user: user)
        // Bind this session's client while its validated credentials are present,
        // before asynchronous services or pending reports can outlive sign-out.
        _ = session.client
        return session
    }
}
