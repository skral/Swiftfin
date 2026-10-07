//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import JellyfinAPI
import SwiftUI

struct CinematicSelectionContentGroup: ContentGroup {

    let id = "cinematic-selection"
    let viewModel: CinematicSelectionContentGroupViewModel

    var _shouldBeResolved: Bool {
        viewModel.elements.isNotEmpty
    }

    init(resumeLibrary: ResumeItemsLibrary, nextUpLibrary: NextUpLibrary) {
        self.viewModel = CinematicSelectionContentGroupViewModel(
            resumeLibrary: resumeLibrary,
            nextUpLibrary: nextUpLibrary
        )
    }

    func body(with viewModel: CinematicSelectionContentGroupViewModel) -> some View {
        SelectionView(viewModel: viewModel)
    }

    private struct SelectionView: View {

        @Environment(\.frameForParentView)
        private var frameForParentView

        @ObservedObject
        var viewModel: CinematicSelectionContentGroupViewModel

        @Router
        private var router

        private var parentFrame: CGRect {
            frameForParentView[.scrollView, default: .zero].frame
        }

        private func itemSelectorImageSource(for item: BaseItemDto) -> ImageSource? {
            if item.type == .episode {
                item.imageSource(
                    .logo,
                    itemID: item.parentLogoItemID,
                    tag: item.parentLogoImageTag,
                    environment: ImageSourceOptions(
                        maxWidth: CinematicSelectionLayout.logoMaxWidth,
                        maxHeight: CinematicSelectionLayout.logoMaxHeight
                    )
                )
            } else {
                item.imageSource(
                    .logo,
                    itemID: item.id,
                    environment: ImageSourceOptions(
                        maxWidth: CinematicSelectionLayout.logoMaxWidth,
                        maxHeight: CinematicSelectionLayout.logoMaxHeight
                    )
                )
            }
        }

        var body: some View {
            CinematicItemSelector(
                items: viewModel.elements
            ) { item in
                router.route(to: .item(item: item))
            } topContent: { item in
                ImageView(itemSelectorImageSource(for: item))
                    .placeholder { _ in
                        EmptyView()
                    }
                    .failure {
                        Text(item.displayTitle)
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                    }
                    .edgePadding(.leading)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: CinematicSelectionLayout.logoMaxHeight, alignment: .bottomLeading)
                    .frame(maxWidth: CinematicSelectionLayout.logoMaxWidth)
            }
            .preference(
                key: ContentGroupCustomizationKey.self,
                value: .ignoreSafeAreaTop
            )
        }
    }
}

final class CinematicSelectionContentGroupViewModel: ViewModel, WithRefresh {

    typealias Background = CinematicSelectionContentGroupViewModel

    let resumeViewModel: PagingLibraryViewModel<ResumeItemsLibrary>
    let nextUpViewModel: PagingLibraryViewModel<NextUpLibrary>

    var elements: [BaseItemDto] {
        (resumeViewModel.elements.elements + nextUpViewModel.elements.elements)
            .uniqued { $0.id }
    }

    var background: CinematicSelectionContentGroupViewModel {
        get { self }
        set {}
    }

    init(resumeLibrary: ResumeItemsLibrary, nextUpLibrary: NextUpLibrary) {
        self.resumeViewModel = PagingLibraryViewModel(library: resumeLibrary, pageSize: 20)
        self.nextUpViewModel = PagingLibraryViewModel(library: nextUpLibrary, pageSize: 20)
        super.init()

        resumeViewModel.objectWillChange
            .merge(with: nextUpViewModel.objectWillChange)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        Task { await refresh() }
    }

    func refreshForPlayback() async -> Bool {
        async let resume = resumeViewModel.refreshForPlayback()
        async let nextUp = nextUpViewModel.refreshForPlayback()
        let results = await (resume, nextUp)
        return results.0 && results.1
    }

    func refresh() async {
        async let resume: Void = resumeViewModel.refresh()
        async let nextUp: Void = nextUpViewModel.refresh()
        _ = await (resume, nextUp)
    }
}

private enum CinematicSelectionLayout {

    static let logoMaxHeight: CGFloat = 100
    static let logoMaxWidth: CGFloat = 450
}
