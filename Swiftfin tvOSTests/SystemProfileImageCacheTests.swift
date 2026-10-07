//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Nuke
@testable import Swiftfin
import XCTest

final class SystemProfileImageCacheTests: XCTestCase {
    func testDifferentServersCannotReuseTheSameArtworkKey() throws {
        let adult = try XCTUnwrap(URL(string: "https://adult.example/Items/same-id/Images/Primary?tag=same-tag"))
        let kids = try XCTUnwrap(URL(string: "https://kids.example/Items/same-id/Images/Primary?tag=same-tag"))
        let adultKey = try XCTUnwrap(ImagePipeline.cacheKey(for: adult))
        let kidsKey = try XCTUnwrap(ImagePipeline.cacheKey(for: kids))
        XCTAssertNotEqual(adultKey, kidsKey)
    }

    func testDifferentImageWidthsRemainDistinct() throws {
        let small = try XCTUnwrap(URL(string: "https://server.example/Items/id/Images/Primary?maxWidth=200&tag=tag"))
        let large = try XCTUnwrap(URL(string: "https://server.example/Items/id/Images/Primary?maxWidth=400&tag=tag"))
        XCTAssertNotEqual(try XCTUnwrap(ImagePipeline.cacheKey(for: small)), try XCTUnwrap(ImagePipeline.cacheKey(for: large)))
    }
}
