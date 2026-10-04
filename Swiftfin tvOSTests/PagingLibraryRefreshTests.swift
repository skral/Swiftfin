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

@MainActor
private final class RefreshLibrary: PagingLibrary {
    typealias Element = BaseItemDto
    typealias Environment = Empty
    let parent = TitledLibraryParent(displayTitle: "Next Up")
    var onRetrieval: (() -> Void)?
    private var continuation: CheckedContinuation<[BaseItemDto], Error>?

    func retrievePage(environment: Empty, pageState: LibraryPageState) async throws -> [BaseItemDto] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onRetrieval?()
        }
    }

    func finish(_ result: Result<[BaseItemDto], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
final class PagingLibraryRefreshTests: XCTestCase {
    private func session() -> UserSession {
        let url = URL(string: "https://server.example")!
        return UserSession(
            server: ServerState(urls: [url], currentURL: url, name: "Server", id: "server", userIDs: ["user"]),
            user: UserState(id: "user", serverID: "server", username: "User")
        )
    }

    func testPlaybackRefreshWaitsForSuccessfulReplacement() async {
        let library = RefreshLibrary()
        let model = PagingLibraryViewModel(library: library)
        model.userSession = session()
        model.elements.append(BaseItemDto(id: "old"))
        let requested = expectation(description: "Retrieval started")
        library.onRetrieval = { requested.fulfill() }
        let refresh = Task { await model.refreshForPlayback() }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(model.elements.map(\.id), ["old"])
        library.finish(.success([BaseItemDto(id: "next")]))
        let refreshed = await refresh.value
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.elements.map(\.id), ["next"])
    }

    func testFailedRefreshKeepsExistingItemsAndDoesNotAcknowledge() async {
        let library = RefreshLibrary()
        let model = PagingLibraryViewModel(library: library)
        model.userSession = session()
        model.elements.append(BaseItemDto(id: "old"))
        let requested = expectation(description: "Retrieval started")
        library.onRetrieval = { requested.fulfill() }
        let refresh = Task { await model.refreshForPlayback() }
        await fulfillment(of: [requested], timeout: 2)
        library.finish(.failure(URLError(.badServerResponse)))
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.elements.map(\.id), ["old"])
    }

    func testSameIdentitySessionReplacementDiscardsOldResponse() async {
        let library = RefreshLibrary()
        let model = PagingLibraryViewModel(library: library)
        model.userSession = session()
        model.elements.append(BaseItemDto(id: "old"))
        let requested = expectation(description: "Retrieval started")
        library.onRetrieval = { requested.fulfill() }
        let refresh = Task { await model.refreshForPlayback() }
        await fulfillment(of: [requested], timeout: 2)
        model.userSession = session()
        library.finish(.success([BaseItemDto(id: "stale")]))
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.elements.map(\.id), ["old"])
    }

    func testCancelingPlaybackRefreshDiscardsReturnedItems() async {
        let library = RefreshLibrary()
        let model = PagingLibraryViewModel(library: library)
        model.userSession = session()
        model.elements.append(BaseItemDto(id: "old"))
        let requested = expectation(description: "Retrieval started")
        library.onRetrieval = { requested.fulfill() }
        let refresh = Task { await model.refreshForPlayback() }
        await fulfillment(of: [requested], timeout: 2)
        refresh.cancel()
        library.finish(.success([BaseItemDto(id: "canceled")]))
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.elements.map(\.id), ["old"])
    }

    func testCanceledRefreshDiscardsReturnedItems() async {
        let library = RefreshLibrary()
        let model = PagingLibraryViewModel(library: library)
        model.userSession = session()
        model.elements.append(BaseItemDto(id: "old"))
        let requested = expectation(description: "Retrieval started")
        library.onRetrieval = { requested.fulfill() }
        let refresh = Task { await model.refreshForPlayback() }
        await fulfillment(of: [requested], timeout: 2)
        model.core.cancelAll()
        library.finish(.success([BaseItemDto(id: "canceled")]))
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.elements.map(\.id), ["old"])
    }

    func testBusyPlaybackRefreshDoesNotAcknowledgeAnotherRequest() async {
        let library = RefreshLibrary()
        let model = PagingLibraryViewModel(library: library)
        model.userSession = session()
        let requested = expectation(description: "Retrieval started")
        library.onRetrieval = { requested.fulfill() }
        let refresh = Task { await model.refreshForPlayback() }
        await fulfillment(of: [requested], timeout: 2)
        let busyResult = await model.refreshForPlayback()
        XCTAssertFalse(busyResult)
        library.finish(.success([BaseItemDto(id: "next")]))
        let refreshed = await refresh.value
        XCTAssertTrue(refreshed)
    }
}
