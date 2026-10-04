//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import JellyfinAPI

@MainActor
@Stateful
final class ContentGroupViewModel<Provider: ContentGroupProvider>: ViewModel {

    @CasePathable
    enum Action {
        case refresh

        var transition: Transition {
            .to(.refreshing, then: .content)
                .whenBackground(.refreshing)
        }
    }

    enum BackgroundState {
        case refreshing
    }

    enum State {
        case content
        case error
        case initial
        case refreshing
    }

    @Published
    private(set) var groups: [any ContentGroup] = []

    private var candidateGroups: [any ContentGroup] = []
    private var isVisible = false
    private var refreshIsRunning = false
    private var hasLoadedGroups = false
    private var playbackRetryRequested = false
    private var playbackRefreshTask: Task<Void, Never>?
    private var playbackSession: UserSession?
    private var playbackGeneration: UInt64 = 0
    private var acknowledgedPlaybackGeneration: UInt64 = 0

    private var isPlaybackHome: Bool {
        #if os(tvOS)
        provider.id == DefaultContentGroupProvider().id
        #else
        false
        #endif
    }

    private var hasPendingPlayback: Bool {
        playbackGeneration > acknowledgedPlaybackGeneration
    }

    private var lastRefreshDate = Date.distantPast
    private var lastRefreshSignalDate = Date.distantPast

    private var hasPendingRefreshSignals: Bool {
        lastRefreshSignalDate > lastRefreshDate
    }

    var provider: Provider

    init(provider: Provider) {
        self.provider = provider
        super.init()

        Publishers.Merge(
            Notifications[.itemUserDataDidChange].publisher.map { _ in () },
            Notifications[.itemMetadataDidChange].publisher.map { _ in () }
        )
        .sink { [weak self] _ in
            self?.lastRefreshSignalDate = Date.now
        }
        .store(in: &cancellables)

        #if os(tvOS)
        if isPlaybackHome {
            Notifications[.didSendStopReport].publisher
                .sink { [weak self] origin in
                    guard let self, let session = userSession,
                          origin.serverID == session.server.id,
                          origin.userID == session.user.id
                    else { return }
                    synchronizePlaybackSession()
                    playbackGeneration += 1
                    schedulePlaybackRefresh(retryIfBusy: true)
                }
                .store(in: &cancellables)
        }
        #endif
    }

    private func synchronizePlaybackSession() {
        guard playbackSession !== userSession else { return }
        playbackSession = userSession
        playbackGeneration = 0
        acknowledgedPlaybackGeneration = 0
    }

    func didAppear() {
        isVisible = true
        synchronizePlaybackSession()
        schedulePlaybackRefresh(retryIfBusy: true)
    }

    func didDisappear() {
        isVisible = false
    }

    private func schedulePlaybackRefresh(retryIfBusy: Bool = false) {
        guard isVisible, hasPendingPlayback, hasLoadedGroups else { return }
        guard !refreshIsRunning, playbackRefreshTask == nil else {
            if retryIfBusy { playbackRetryRequested = true }
            return
        }
        playbackRetryRequested = false

        playbackRefreshTask = Task { [weak self] in
            guard let self else { return }
            // The action function finishes before StateCore clears its state.
            // Wait for that terminal boundary before beginning a trailing pass.
            if core.backgroundStates.contains(.refreshing) {
                for await states in core.$backgroundStates.values {
                    if !states.contains(.refreshing) { break }
                }
            }
            guard isVisible, hasPendingPlayback else {
                playbackRefreshTask = nil
                return
            }
            let generation = playbackGeneration
            let session = userSession
            try? await core.send(\.refresh, background: true)
            playbackRefreshTask = nil
            // A newer accepted stop is a new retry trigger, even if this pass failed.
            if playbackRetryRequested || playbackGeneration > generation ||
                (session !== userSession && hasPendingPlayback) { schedulePlaybackRefresh() }
        }
    }

    func refreshIfNeeded(
        sinceLastDisappear interval: TimeInterval,
        staleThreshold: TimeInterval = 60
    ) {
        didAppear()
        if hasPendingPlayback { return }
        guard interval > staleThreshold || hasPendingRefreshSignals else { return }

        background.refresh()
    }

    func refreshIfPendingChanges() {
        synchronizePlaybackSession()
        if hasPendingPlayback {
            schedulePlaybackRefresh(retryIfBusy: true)
            return
        }
        guard hasPendingRefreshSignals else { return }

        refresh()
    }

    @Function(\Action.Cases.refresh)
    private func _refresh() async throws {
        guard !refreshIsRunning else { return }
        synchronizePlaybackSession()
        let session = userSession
        let generation = playbackGeneration
        let isBackground = StateTask.isBackground
        refreshIsRunning = true
        var succeeded = false
        defer {
            refreshIsRunning = false
            if playbackRetryRequested || playbackGeneration > generation || (session !== userSession && hasPendingPlayback) ||
                (!isBackground && succeeded && hasPendingPlayback)
            {
                schedulePlaybackRefresh()
            }
        }

        if isBackground && hasPendingPlayback {
            let success = await refreshPlaybackViewModels()
            guard success, !Task.isCancelled, userSession === session else { return }
            resolveGroups()
            acknowledgedPlaybackGeneration = generation
        } else if isBackground {
            try await backgroundRefresh()
        } else {
            try await fullRefresh()
        }

        guard !Task.isCancelled, userSession === session else { return }
        succeeded = true
        lastRefreshDate = Date.now
    }

    private func refreshPlaybackViewModels() async -> Bool {
        let viewModels = candidateGroups.map { getViewModel(for: $0) }
            .uniqued { ObjectIdentifier($0 as AnyObject) }
        return await withTaskGroup(of: Bool.self) { group in
            for viewModel in viewModels {
                group.addTask { await viewModel.refreshForPlayback() }
            }
            var success = true
            for await result in group {
                success = result && success
            }
            return success
        }
    }

    private func getViewModel(for group: some ContentGroup) -> any WithRefresh {
        group.viewModel
    }

    private func resolveGroups() {
        groups = candidateGroups
            .filter(\._shouldBeResolved)
    }

    private func refreshViewModels(
        for groups: [any ContentGroup],
        inBackground: Bool
    ) async throws {
        let viewModels = groups.map { getViewModel(for: $0) }
            .uniqued { ObjectIdentifier($0 as AnyObject) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for viewModel in viewModels {
                group.addTask {
                    if inBackground {
                        await viewModel.background.refresh()
                    } else {
                        await viewModel.refresh()
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    private func backgroundRefresh() async throws {
        try await refreshViewModels(
            for: candidateGroups,
            inBackground: true
        )

        resolveGroups()
    }

    private func fullRefresh() async throws {

        self.groups = []
        self.candidateGroups = []

        let session = userSession
        let newGroups = try await provider.makeGroups(environment: provider.environment)

        try await refreshViewModels(
            for: newGroups,
            inBackground: false
        )

        guard !Task.isCancelled, userSession === session else { return }
        hasLoadedGroups = true
        candidateGroups = newGroups
        resolveGroups()
    }
}
