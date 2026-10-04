//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import JellyfinAPI
@testable import Swiftfin
import XCTest

/// Controls the actual Jellyfin HTTP boundary, without replacing stop reporting.
private final class StopReportURLProtocol: URLProtocol, @unchecked Sendable {
    static var onRequest: ((StopReportURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.onRequest?(self)
    }

    override func stopLoading() {}

    func succeed() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: URLError) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

@MainActor
final class MediaProgressObserverTests: XCTestCase {
    private var originalReporting = true
    private var tokens = Set<AnyCancellable>()

    override func setUp() async throws {
        originalReporting = Defaults[.sendProgressReports]
        Defaults[.sendProgressReports] = true
    }

    override func tearDown() async throws {
        Defaults[.sendProgressReports] = originalReporting
        StopReportURLProtocol.onRequest = nil
        tokens.removeAll()
    }

    private func session(serverID: String = "origin-server", userID: String = "origin-user") -> UserSession {
        let url = URL(string: "https://\(serverID).example")!
        let session = UserSession(
            server: ServerState(urls: [url], currentURL: url, name: serverID, id: serverID, userIDs: [userID]),
            user: UserState(id: userID, serverID: serverID, username: userID)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StopReportURLProtocol.self]
        session.client = JellyfinClient(
            configuration: .init(url: url, client: "Tests", deviceName: "Tests", deviceID: "Tests", version: "1"),
            sessionConfiguration: configuration
        )
        return session
    }

    private func playback() -> (MediaPlayerItem, MediaPlayerManager, MediaProgressObserver) {
        let item = MediaPlayerItem(
            baseItem: BaseItemDto(id: "episode-3"),
            mediaSource: MediaSourceInfo(id: "source-3"),
            playSessionID: "play-session-3",
            url: URL(string: "https://media.example/episode-3")!,
            deviceProfile: DeviceProfile()
        )
        let observer = item.observers.compactMap { $0 as? MediaProgressObserver }.first!
        observer.userSession = session()
        let manager = MediaPlayerManager(playbackItem: item)
        manager.seconds = .seconds(120)
        return (item, manager, observer)
    }

    func testSuccessWaitsForAcknowledgmentAndSurvivesTeardown() async throws {
        let requested = expectation(description: "Actual stop request")
        var transport: StopReportURLProtocol?
        StopReportURLProtocol.onRequest = {
            transport = $0
            requested.fulfill()
        }
        let published = expectation(description: "Successful stop notification")
        var eventCount = 0
        Notifications[.didSendStopReport].publisher.sink { _ in
            eventCount += 1
            published.fulfill()
        }.store(in: &tokens)

        var (item, manager, observer): (MediaPlayerItem, MediaPlayerManager, MediaProgressObserver?) = playback()
        weak let weakObserver = observer
        Notifications[.applicationWillTerminate].post()
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(transport?.request.url?.path, "/Sessions/Playing/Stopped")
        XCTAssertEqual(transport?.request.url?.host, "origin-server.example")
        let request = try XCTUnwrap(transport?.request)
        let body: Data
        if let data = request.httpBody {
            body = data
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["ItemId"] as? String, "episode-3")
        XCTAssertEqual(fields["PlaySessionId"] as? String, "play-session-3")
        XCTAssertEqual(fields["PositionTicks"] as? Int, 1_200_000_000)

        item.observers.removeAll()
        observer?.manager = nil
        observer = nil
        XCTAssertNil(weakObserver)
        transport?.succeed()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(eventCount, 1)
        withExtendedLifetime(manager) {}
    }

    func testSessionSwitchBeforeTaskStartsKeepsOriginatingClientAndIdentity() async {
        let requested = expectation(description: "Originating client sends stop")
        var transport: StopReportURLProtocol?
        StopReportURLProtocol.onRequest = {
            transport = $0
            requested.fulfill()
        }
        let published = expectation(description: "Originating identity published")
        var origins = [PlaybackStopReportOrigin]()
        Notifications[.didSendStopReport].publisher.sink {
            origins.append($0)
            published.fulfill()
        }.store(in: &tokens)
        let (item, manager, observer) = playback()
        Notifications[.applicationWillTerminate].post()
        observer.userSession = session(serverID: "other-server", userID: "other-user")
        manager.seconds = .seconds(999)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(transport?.request.url?.host, "origin-server.example")
        XCTAssertTrue(origins.isEmpty)
        transport?.succeed()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(origins, [PlaybackStopReportOrigin(serverID: "origin-server", userID: "origin-user")])
        item.observers.removeAll()
        withExtendedLifetime(manager) {}
    }

    func testFailedAndCanceledRequestsDoNotPublishSuccess() async {
        for error in [URLError(.badServerResponse), URLError(.cancelled)] {
            let requested = expectation(description: "Stop request")
            var transport: StopReportURLProtocol?
            StopReportURLProtocol.onRequest = {
                transport = $0
                requested.fulfill()
            }
            let noEvent = expectation(description: "No successful stop")
            noEvent.isInverted = true
            Notifications[.didSendStopReport].publisher.sink { _ in noEvent.fulfill() }.store(in: &tokens)
            let (item, manager, _) = playback()
            Notifications[.applicationWillTerminate].post()
            await fulfillment(of: [requested], timeout: 2)
            transport?.fail(error)
            await fulfillment(of: [noEvent], timeout: 0.1)
            item.observers.removeAll()
            tokens.removeAll()
            withExtendedLifetime(manager) {}
        }
    }

    func testDisabledDebugReportingDoesNotSendOrPublish() async {
        Defaults[.sendProgressReports] = false
        let noRequest = expectation(description: "Reporting remains disabled")
        noRequest.isInverted = true
        StopReportURLProtocol.onRequest = { _ in noRequest.fulfill() }
        let noEvent = expectation(description: "No successful stop")
        noEvent.isInverted = true
        Notifications[.didSendStopReport].publisher.sink { _ in noEvent.fulfill() }.store(in: &tokens)
        let (item, manager, _) = playback()
        Notifications[.applicationWillTerminate].post()
        await fulfillment(of: [noRequest, noEvent], timeout: 0.1)
        item.observers.removeAll()
        withExtendedLifetime(manager) {}
    }
}
