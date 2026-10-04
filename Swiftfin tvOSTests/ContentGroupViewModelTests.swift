//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
@testable import Swiftfin
import XCTest

private final class HomeRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var nextUp = "episode-3"
        var nextUpRequests = 0
        var resumeItems = "[]"
        var resumeRequests = 0
        var recentlyAddedItems = "[{\"Id\":\"fallback\",\"Type\":\"Movie\"}]"
        var onNextUp: (@MainActor (HomeRefreshURLProtocol) -> Void)?
    }

    private static let lock = NSLock()
    private static var state = State()
    private static func read<T>(_ key: KeyPath<State, T>) -> T {
        lock.withLock { state[keyPath: key] }
    }

    private static func write<T>(_ key: WritableKeyPath<State, T>, _ value: T) {
        lock.withLock { state[keyPath: key] = value }
    }

    static var nextUp: String {
        get { read(\.nextUp) } set { write(\.nextUp, newValue) }
    }

    static var nextUpRequests: Int {
        get { read(\.nextUpRequests) } set { write(\.nextUpRequests, newValue) }
    }

    static var resumeItems: String {
        get { read(\.resumeItems) } set { write(\.resumeItems, newValue) }
    }

    static var resumeRequests: Int {
        get { read(\.resumeRequests) } set { write(\.resumeRequests, newValue) }
    }

    static var recentlyAddedItems: String {
        get { read(\.recentlyAddedItems) } set { write(\.recentlyAddedItems, newValue) }
    }

    static var onNextUp: (@MainActor (HomeRefreshURLProtocol) -> Void)? {
        get { read(\.onNextUp) } set { write(\.onNextUp, newValue) }
    }

    private var responseBody: Data?
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}
    override func startLoading() {
        let isNextUp = request.url!.path.contains("NextUp")
        if isNextUp { Self.lock.withLock { Self.state.nextUpRequests += 1 } }
        let isResume = request.url!.path.contains("Resume")
        if isResume { Self.lock.withLock { Self.state.resumeRequests += 1 } }
        let items = request.url!.path == "/Items" ? Self.recentlyAddedItems : isResume ? Self.resumeItems : isNextUp && !Self.nextUp
            .isEmpty ? "[{\"Id\":\"\(Self.nextUp)\",\"Type\":\"Episode\"}]" : "[]"
        let data = Data("{\"Items\":\(items),\"TotalRecordCount\":0}".utf8)
        responseBody = data
        if isNextUp, let onNextUp = Self.onNextUp {
            Task { @MainActor in onNextUp(self) }
            return
        }
        succeed()
    }

    func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
    }

    func succeed() {
        let data = responseBody!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class ContentGroupViewModelTests: XCTestCase {
    override func tearDown() async throws {
        HomeRefreshURLProtocol.onNextUp = nil
    }

    private let origin = PlaybackStopReportOrigin(serverID: "server", userID: "user")
    private func settle(_ home: ContentGroupViewModel<HomeRefreshProvider>, minimumRequests: Int = 2) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if HomeRefreshURLProtocol.nextUpRequests >= minimumRequests,
               !home.background.is(.refreshing) { return }
            await Task.yield()
        }
        XCTFail("Home refresh did not finish")
    }

    private func nextIDs(_ home: ContentGroupViewModel<HomeRefreshProvider>) -> [String?] {
        home.groups.compactMap { $0 as? PosterGroup<NextUpLibrary> }.first?.viewModel.elements.map(\.id) ?? []
    }

    private func home() async -> ContentGroupViewModel<HomeRefreshProvider> {
        HomeRefreshURLProtocol.nextUp = "episode-3"
        HomeRefreshURLProtocol.nextUpRequests = 0
        HomeRefreshURLProtocol.resumeRequests = 0
        HomeRefreshURLProtocol.resumeItems = "[]"
        HomeRefreshURLProtocol.onNextUp = nil
        let url = URL(string: "https://home.example")!
        let session = UserSession(
            server: ServerState(urls: [url], currentURL: url, name: "Home", id: "server", userIDs: ["user"]),
            user: UserState(id: "user", serverID: "server", username: "user")
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRefreshURLProtocol.self]
        session.client = JellyfinClient(
            configuration: .init(url: url, client: "Tests", deviceName: "Tests", deviceID: "Tests", version: "1"),
            sessionConfiguration: configuration
        )
        var provider = DefaultContentGroupProvider()
        provider.userSession = session
        var groups = try! await provider.makeGroups(environment: Empty())
        for group in groups {
            if let next = group as? PosterGroup<NextUpLibrary> { next.viewModel.userSession = session }
            if let recommended = group as? PosterGroup<RecommendedProgramsLibrary> { recommended.viewModel.userSession = session }
            if let recent = group as? PosterGroup<ItemLibrary> { recent.viewModel.userSession = session }
            if let cinematic = group as? CinematicSelectionContentGroup {
                cinematic.viewModel.userSession = session
                cinematic.viewModel.resumeViewModel.userSession = session
                cinematic.viewModel.recentlyAddedViewModel.userSession = session
            }
        }
        if let cinematic = groups.compactMap({ $0 as? CinematicSelectionContentGroup }).first {
            groups.append(CinematicRecentlyAddedContentGroup(viewModel: cinematic.viewModel))
        }
        let home = ContentGroupViewModel(provider: HomeRefreshProvider(content: groups))
        home.userSession = session
        await home.refresh()
        return home
    }

    func testSuccessfulStopBeforeQuickReturnRetrievesNextEpisode() async {
        let home = await home()
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 1)
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.didSendStopReport].post(PlaybackStopReportOrigin(serverID: "server", userID: "user"))
        home.refreshIfNeeded(sinceLastDisappear: 10)
        await settle(home)
        let next = home.groups.compactMap { $0 as? PosterGroup<NextUpLibrary> }.first
        XCTAssertEqual(next?.viewModel.elements.first?.id, "episode-4")
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
    }

    func testLateSignalRefreshesVisibleHomeAndDifferentSessionIsIgnored() async {
        let home = await home()
        home.didAppear()
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.didSendStopReport].post(PlaybackStopReportOrigin(serverID: "other", userID: "user"))
        await settle(home, minimumRequests: 1)
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 1)
        Notifications[.didSendStopReport].post(origin)
        await settle(home)
        XCTAssertEqual(nextIDs(home), ["episode-4"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
        home.didDisappear()
        HomeRefreshURLProtocol.nextUp = "episode-5"
        Notifications[.didSendStopReport].post(origin)
        await settle(home)
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
        home.refreshIfNeeded(sinceLastDisappear: 5)
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["episode-5"])
    }

    func testNewSignalDuringRetrievalCoalescesAndRequiresTrailingPass() async {
        let home = await home()
        home.didAppear()
        let requested = expectation(description: "First pending retrieval")
        var transport: HomeRefreshURLProtocol?
        HomeRefreshURLProtocol.onNextUp = { request in
            transport = request
            requested.fulfill()
        }
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.didSendStopReport].post(origin)
        await fulfillment(of: [requested], timeout: 2)
        HomeRefreshURLProtocol.nextUp = "episode-5"
        Notifications[.didSendStopReport].post(origin)
        Notifications[.didSendStopReport].post(origin)
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
        HomeRefreshURLProtocol.onNextUp = nil
        transport?.succeed()
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["episode-5"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 3)
    }

    func testFailurePreservesRowsAndPendingSignalUntilForegroundRetry() async {
        let home = await home()
        home.didAppear()
        let requested = expectation(description: "Failed retrieval")
        HomeRefreshURLProtocol.onNextUp = { request in request.fail()
            requested.fulfill()
        }
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.didSendStopReport].post(origin)
        await fulfillment(of: [requested], timeout: 2)
        await settle(home)
        XCTAssertEqual(nextIDs(home), ["episode-3"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
        HomeRefreshURLProtocol.onNextUp = nil
        home.refreshIfPendingChanges()
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["episode-4"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 3)
    }

    func testEmptyNextUpRestoresAndResumeUsesServerProgress() async throws {
        let home = await home()
        home.didAppear()
        HomeRefreshURLProtocol.nextUp = ""
        HomeRefreshURLProtocol.resumeItems = "[{\"Id\":\"movie\",\"Type\":\"Movie\",\"UserData\":{\"Key\":\"movie\",\"PlaybackPositionTicks\":100}}]"
        Notifications[.didSendStopReport].post(origin)
        await settle(home)
        XCTAssertEqual(nextIDs(home), [])
        let cinematic = try XCTUnwrap(home.provider.content.compactMap { $0 as? CinematicSelectionContentGroup }.first)
        XCTAssertEqual(cinematic.viewModel.resumeViewModel.elements.first?.userData?.playbackPositionTicks, 100)
        HomeRefreshURLProtocol.nextUp = "episode-4"
        HomeRefreshURLProtocol.resumeItems = "[{\"Id\":\"movie\",\"Type\":\"Movie\",\"UserData\":{\"Key\":\"movie\",\"PlaybackPositionTicks\":200}}]"
        Notifications[.didSendStopReport].post(origin)
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["episode-4"])
        XCTAssertEqual(cinematic.viewModel.resumeViewModel.elements.first?.userData?.playbackPositionTicks, 200)
        HomeRefreshURLProtocol.resumeItems = "[]"
        Notifications[.didSendStopReport].post(origin)
        await settle(home, minimumRequests: 4)
        XCTAssertTrue(cinematic.viewModel.resumeViewModel.elements.isEmpty)
        XCTAssertTrue(cinematic.viewModel.hasContent)
        XCTAssertEqual(cinematic.viewModel.recentlyAddedViewModel.elements.first?.id, "fallback")
        XCTAssertEqual(HomeRefreshURLProtocol.resumeRequests, 4, "Shared cinematic models retrieve once per pass")
    }

    func testSignalDuringOrdinaryRefreshRunsTrailingPassWithoutParallelRetrieval() async {
        let home = await home()
        home.didAppear()
        let requested = expectation(description: "Ordinary background retrieval")
        var transport: HomeRefreshURLProtocol?
        HomeRefreshURLProtocol.onNextUp = { request in transport = request
            requested.fulfill()
        }
        let ordinary = Task { await home.background.refresh() }
        await fulfillment(of: [requested], timeout: 2)
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.didSendStopReport].post(origin)
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
        XCTAssertEqual(home.state, .content)
        HomeRefreshURLProtocol.onNextUp = nil
        transport?.succeed()
        await ordinary.value
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["episode-4"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 3)
    }

    func testSessionChangeCannotApplyOldResponseOrLoseNewSignal() async throws {
        let home = await home()
        home.didAppear()
        let requested = expectation(description: "Old session retrieval")
        var transport: HomeRefreshURLProtocol?
        HomeRefreshURLProtocol.onNextUp = { request in transport = request
            requested.fulfill()
        }
        HomeRefreshURLProtocol.nextUp = "old-session-item"
        Notifications[.didSendStopReport].post(origin)
        await fulfillment(of: [requested], timeout: 2)
        let oldSession = try XCTUnwrap(home.userSession)
        let replacement = UserSession(server: oldSession.server, user: oldSession.user)
        replacement.client = oldSession.client
        home.userSession = replacement
        for group in home.provider.content {
            (group.viewModel as? ViewModel)?.userSession = replacement
            if let cinematic = group as? CinematicSelectionContentGroup {
                cinematic.viewModel.resumeViewModel.userSession = replacement
                cinematic.viewModel.recentlyAddedViewModel.userSession = replacement
            }
        }
        HomeRefreshURLProtocol.nextUp = "new-session-item"
        Notifications[.didSendStopReport].post(origin)
        HomeRefreshURLProtocol.onNextUp = nil
        transport?.succeed()
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["new-session-item"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 3)
    }

    func testCanceledChildLeavesChangePendingForNextReturn() async throws {
        let home = await home()
        home.didAppear()
        let next = try XCTUnwrap(home.provider.content.compactMap { $0 as? PosterGroup<NextUpLibrary> }.first)
        let requested = expectation(description: "Cancelable child retrieval")
        var transport: HomeRefreshURLProtocol?
        HomeRefreshURLProtocol.onNextUp = { request in transport = request
            requested.fulfill()
        }
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.didSendStopReport].post(origin)
        await fulfillment(of: [requested], timeout: 2)
        next.viewModel.core.cancelAll()
        HomeRefreshURLProtocol.onNextUp = nil
        transport?.succeed()
        await settle(home)
        XCTAssertEqual(nextIDs(home), ["episode-3"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
        home.didDisappear()
        home.refreshIfNeeded(sinceLastDisappear: 5)
        await settle(home, minimumRequests: 3)
        XCTAssertEqual(nextIDs(home), ["episode-4"])
    }

    func testOrdinaryItemDataSignalKeepsShortReturnRefreshBehavior() async {
        let home = await home()
        HomeRefreshURLProtocol.nextUp = "episode-4"
        Notifications[.itemUserDataDidChange].post(UserItemDataDto(key: "item-key"))
        home.refreshIfNeeded(sinceLastDisappear: 5)
        await settle(home)
        XCTAssertEqual(nextIDs(home), ["episode-4"])
        XCTAssertEqual(HomeRefreshURLProtocol.nextUpRequests, 2)
    }
}

@MainActor
private struct HomeRefreshProvider: ContentGroupProvider {
    let id = "default-content-group-provider"
    let displayTitle = "Home"
    let content: [any ContentGroup]
    func makeGroups(environment: Empty) async throws -> [any ContentGroup] {
        content
    }
}
