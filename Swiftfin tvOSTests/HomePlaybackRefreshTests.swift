//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import Swiftfin
import XCTest

@MainActor
final class HomePlaybackRefreshTests: XCTestCase {
    func testShortOrdinaryNavigationKeepsExistingContent() async {
        let content = PlaybackRefreshContent()
        let home = ContentGroupViewModel(provider: PlaybackRefreshProvider(content: content))
        await home.refresh()
        XCTAssertEqual(home.groups.map(\.id), ["next-up"])
        XCTAssertEqual(content.retrievalCount, 1)

        content.serverEpisodeIDs = ["episode-4"]
        home.refreshIfNeeded(sinceLastDisappear: 10)
        await Task.yield()

        XCTAssertEqual(content.episodeIDs, ["episode-3"])
        XCTAssertEqual(content.retrievalCount, 1)
    }

    /// Characterization of the existing handoff: authoritative state has advanced,
    /// but a short return without a consumed change signal leaves episode 3 cached.
    /// This proves lifecycle suppression, not a live Jellyfin playback failure.
    func testCharacterizesShortPlaybackReturnWithoutChangeSignal() async {
        let content = PlaybackRefreshContent()
        let home = ContentGroupViewModel(provider: PlaybackRefreshProvider(content: content))
        await home.refresh()
        content.serverEpisodeIDs = ["episode-4"]

        home.refreshIfNeeded(sinceLastDisappear: 30)
        await Task.yield()

        XCTAssertEqual(content.episodeIDs, ["episode-3"])
        XCTAssertEqual(content.retrievalCount, 1)
    }

    func testStaleReturnRetrievesAndResolvesAuthoritativeContent() async {
        let content = PlaybackRefreshContent()
        let home = ContentGroupViewModel(provider: PlaybackRefreshProvider(content: content))
        await home.refresh()
        content.serverEpisodeIDs = ["episode-4"]
        let retrieved = expectation(description: "Return retrieves updated Next Up")
        content.onRetrieval = { retrieved.fulfill() }

        home.refreshIfNeeded(sinceLastDisappear: 61)
        await fulfillment(of: [retrieved], timeout: 2)

        XCTAssertEqual(content.episodeIDs, ["episode-4"])
        XCTAssertEqual(content.retrievalCount, 2)
        XCTAssertEqual(home.groups.map(\.id), ["next-up"])
    }
}
