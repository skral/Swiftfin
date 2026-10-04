//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import Swiftfin
import SwiftUI

/// A controllable retrieval boundary. Production ContentGroupViewModel decides
/// when to invoke it and whether its group remains visible.
@MainActor
final class PlaybackRefreshContent: WithRefresh {
    var episodeIDs = ["episode-3"]
    var serverEpisodeIDs = ["episode-3"]
    private(set) var retrievalCount = 0
    var onRetrieval: (() -> Void)?

    struct Background: WithRefresh {
        let content: PlaybackRefreshContent

        func refresh() {
            content.refresh()
        }

        func refresh() async {
            await content.refresh()
        }
    }

    var background: Background {
        get { Background(content: self) }
        set {}
    }

    func refresh() {
        retrieve()
    }

    func refresh() async {
        retrieve()
    }

    private func retrieve() {
        retrievalCount += 1
        episodeIDs = serverEpisodeIDs
        onRetrieval?()
    }
}

@MainActor
struct PlaybackRefreshGroup: ContentGroup {
    let id = "next-up"
    let viewModel: PlaybackRefreshContent

    var _shouldBeResolved: Bool {
        !viewModel.episodeIDs.isEmpty
    }

    func body(with viewModel: PlaybackRefreshContent) -> some View {
        EmptyView()
    }
}

@MainActor
struct PlaybackRefreshProvider: ContentGroupProvider {
    let id = "home"
    let displayTitle = "Home"
    let content: PlaybackRefreshContent

    func makeGroups(environment: Empty) async throws -> [any ContentGroup] {
        PlaybackRefreshGroup(viewModel: content)
    }
}
