import Foundation
import Darwin
import Testing
@testable import LanternCore

@Test func onDemandDeadlineIsSharedAndLateSubtitlesAppearOnReopen() async throws {
    let fixture = try CoreTests()
    let first = try fixture.write("Slow.mp4", "0123456789")
    let second = try fixture.write("Fast.mp4", "abcdefghij")
    let subtitle = try fixture.write("prepared.srt", "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    let library = try Library(root: fixture.directory)
    let slowID = Library.id(for: first.resolvingSymlinksInPath()), fastID = Library.id(for: second.resolvingSymlinksInPath())
    let server = DLNAServer(uuid: UUID().uuidString)
    defer { server.shutdown() }
    let state = DispatchQueue(label: "Lantern.on-demand-tests")
    var calls: [String: Int] = [:]
    var finishSlow: ((Bool) -> Void)?
    server.onPrepareVideo = { item, complete in
        state.sync { calls[item.id, default: 0] += 1 }
        if item.id == slowID { state.sync { finishSlow = complete } }
        else {
            server.updateSubtitles([item.id: subtitle], root: library.root)
            complete(true)
        }
    }
    let base: String = try await withCheckedThrowingContinuation { continuation in
        server.onState = { running, detail in
            server.onState = nil
            if running { continuation.resume(returning: detail) }
            else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
        }
        server.start(library: library, interface: LANInterface(name: "lo0", address: "127.0.0.1", mask: inet_addr("255.0.0.0")), port: 0)
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let slowURL = URL(string: "\(base)/media/\(slowID).mp4")!
    let fastURL = URL(string: "\(base)/media/\(fastID).mp4")!
    _ = try await session.data(from: URL(string: base + "/description.xml")!)
    var invalid = URLRequest(url: slowURL); invalid.setValue("bytes=100-", forHTTPHeaderField: "Range")
    let (_, invalidResponse) = try await session.data(for: invalid)
    #expect((invalidResponse as? HTTPURLResponse)?.statusCode == 416)
    #expect(state.sync { calls.isEmpty })
    var head = URLRequest(url: slowURL); head.httpMethod = "HEAD"
    let began = Date()
    let waitingHead = Task { try await session.data(for: head) }
    for _ in 0..<100 {
        if state.sync(execute: { finishSlow != nil }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(state.sync { finishSlow != nil })
    let fastBegan = Date()
    let (fastData, fastResponse) = try await session.data(from: fastURL)
    #expect(Date().timeIntervalSince(fastBegan) < 1)
    #expect(fastData == Data("abcdefghij".utf8))
    #expect((fastResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") != nil)
    var range = URLRequest(url: slowURL); range.setValue("bytes=2-4", forHTTPHeaderField: "Range")
    let waitingRange = Task { try await session.data(for: range) }
    let (headBody, headResponse) = try await waitingHead.value
    let elapsed = Date().timeIntervalSince(began)
    #expect(elapsed >= 4.8 && elapsed < 6)
    #expect(headBody.isEmpty)
    #expect((headResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") == nil)
    let (rangeBody, rangeResponse) = try await waitingRange.value
    #expect(rangeBody == Data("234".utf8))
    #expect((rangeResponse as? HTTPURLResponse)?.statusCode == 206)
    #expect((rangeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 2-4/10")
    let repeatBegan = Date()
    let (_, repeated) = try await session.data(from: slowURL)
    #expect(Date().timeIntervalSince(repeatBegan) < 1)
    #expect((repeated as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") == nil)
    #expect(state.sync { calls[slowID] } == 1)
    server.updateSubtitles([slowID: subtitle], root: library.root)
    let finish = try #require(state.sync { finishSlow })
    finish(true); finish(false)
    let (reopenedData, reopened) = try await session.data(from: slowURL)
    #expect(reopenedData == Data("0123456789".utf8))
    #expect((reopened as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") != nil)
    let (srt, srtResponse) = try await session.data(from: URL(string: "\(base)/subtitles/\(slowID).srt")!)
    #expect((srtResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(srt == (try Data(contentsOf: subtitle)))
    #expect(state.sync { calls[fastID] } == 1)
}

@Test func onDemandRevalidatesPathsAfterWaitingAndRemembersFailure() async throws {
    let fixture = try CoreTests()
    let file = try fixture.write("Example.mp4", "0123456789")
    let other = try fixture.write("Other.mp4", "private synthetic data")
    let library = try Library(root: fixture.directory)
    let id = Library.id(for: file.resolvingSymlinksInPath())
    let state = DispatchQueue(label: "Lantern.on-demand-failure-test")
    var calls = 0
    var finish: ((Bool) -> Void)?
    let server = DLNAServer(uuid: UUID().uuidString)
    defer { server.shutdown() }
    server.onPrepareVideo = { _, complete in state.sync { calls += 1; finish = complete } }
    let base: String = try await withCheckedThrowingContinuation { continuation in
        server.onState = { running, detail in
            server.onState = nil
            if running { continuation.resume(returning: detail) }
            else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
        }
        server.start(library: library, interface: LANInterface(name: "lo0", address: "127.0.0.1", mask: inet_addr("255.0.0.0")), port: 0)
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "\(base)/media/\(id).mp4")!
    let waiting = Task { try await session.data(from: url) }
    for _ in 0..<100 {
        if state.sync(execute: { finish != nil }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let complete = try #require(state.sync { finish })
    complete(false)
    let (_, response) = try await waiting.value
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    _ = try await session.data(from: url)
    #expect(state.sync { calls } == 1)
    try Data("changed file size".utf8).write(to: file)
    let replacement = Task { try await session.data(from: url) }
    for _ in 0..<100 {
        if state.sync(execute: { calls == 2 }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(state.sync { calls } == 2)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
    let replacedComplete = try #require(state.sync { finish })
    replacedComplete(true)
    let (_, rejected) = try await replacement.value
    #expect((rejected as? HTTPURLResponse)?.statusCode == 404)
    try FileManager.default.removeItem(at: file)
    try Data("another replacement file".utf8).write(to: file)
    let stopped = Task { () -> Bool in
        do { _ = try await session.data(from: url); return false }
        catch { return true }
    }
    for _ in 0..<100 {
        if state.sync(execute: { calls == 3 }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(state.sync { calls } == 3)
    let stoppedComplete = try #require(state.sync { finish })
    server.shutdown()
    stoppedComplete(true)
    #expect(await stopped.value)
}
