import Testing
@testable import FrameLoopKit

private func frames(_ count: Int, fps: Double = 10) -> [FrameInfo] {
    (0..<count).map { FrameInfo(index: $0, pts: Double($0) / fps, duration: 1 / fps) }
}

@Test func frameAtTimeSnapsToFrameBefore() {
    let list = frames(10)
    #expect(Timeline.frameAtTime(list, time: 0) == 0)
    #expect(Timeline.frameAtTime(list, time: 0.349) == 3)
    #expect(Timeline.frameAtTime(list, time: 0.35) == 3)
    #expect(Timeline.frameAtTime(list, time: 99) == 9)
    #expect(Timeline.frameAtTime([], time: 1) == 0)
}

@Test func clampStaysInRange() {
    #expect(Timeline.clampFrame(-5, frameCount: 10) == 0)
    #expect(Timeline.clampFrame(20, frameCount: 10) == 9)
    #expect(Timeline.clampFrame(3, frameCount: 0) == 0)
}

@Test func segmentRanges() {
    #expect(Timeline.segmentRanges(Segment(startFrame: 2, endFrame: 5), frameCount: 10) == [2...5])
    #expect(Timeline.segmentRanges(Segment(startFrame: 8, endFrame: 1), frameCount: 10) == [8...9, 0...1])
    #expect(Timeline.segmentRanges(Segment(startFrame: 2), frameCount: 10).isEmpty)
    #expect(Timeline.segmentFrameCount(Segment(startFrame: 8, endFrame: 1), frameCount: 10) == 4)
}

@Test func remainingRanges() {
    #expect(Timeline.remainingRanges(Segment(startFrame: 3, endFrame: 5), frameCount: 10) == [0...2, 6...9])
    #expect(Timeline.remainingRanges(Segment(startFrame: 0, endFrame: 4), frameCount: 10) == [5...9])
    #expect(Timeline.remainingRanges(Segment(startFrame: 5, endFrame: 9), frameCount: 10) == [0...4])
    #expect(Timeline.remainingRanges(Segment(startFrame: 8, endFrame: 1), frameCount: 10) == [2...7])
    #expect(Timeline.remainingRanges(Segment(startFrame: 0, endFrame: 9), frameCount: 10).isEmpty)
    #expect(Timeline.remainingRanges(Segment(startFrame: 4), frameCount: 10) == [0...9])
}

@Test func pingPongOrder() {
    #expect(Timeline.pingPongOrder([0, 1, 2, 3]) == [0, 1, 2, 3, 2, 1])
    #expect(Timeline.pingPongOrder([0, 1]) == [0, 1])
    #expect(Timeline.pingPongOrder([]) == [])
}

@Test func timeFormat() {
    #expect(Timeline.formatTime(65.25) == "01:05.250")
    #expect(Timeline.formatTime(3723.25) == "01:02:03.250")
    #expect(Timeline.formatTime(-1) == "00:00.000")
}

@Test func loopForward() {
    let region = LoopRegion(start: 1, end: 2, clipDuration: 5)
    #expect(region.action(time: 1.5, direction: .forward) == .none)
    #expect(region.action(time: 2.0, direction: .forward) == .jump(1, .forward))
}

@Test func loopPingPong() {
    let region = LoopRegion(start: 1, end: 2, clipDuration: 5, pingPong: true)
    #expect(region.action(time: 2.0, direction: .forward) == .jump(2, .backward))
    #expect(region.action(time: 1.5, direction: .backward) == .none)
    #expect(region.action(time: 1.0, direction: .backward) == .jump(1, .forward))
}

@Test func loopWrap() {
    let region = LoopRegion(start: 4, end: 1, clipDuration: 5, wraps: true)
    #expect(region.action(time: 4.5, direction: .forward) == .none)
    #expect(region.action(time: 5.0, direction: .forward) == .jump(0, .forward))
    #expect(region.action(time: 1.0, direction: .forward) == .jump(4, .forward))
    #expect(region.action(time: 0.5, direction: .forward) == .none)
}

@Test func playTimesFollowTheEditList() {
    let packets = [0, 1, 2, 3].map { Double($0) / 30 }
    // No edit list: untouched.
    #expect(MediaSegment.playTimes(of: packets, segments: []) == packets)
    // An empty edit first pushes every frame later.
    let late = MediaSegment.playTimes(of: packets, segments: [MediaSegment(sourceStart: 0, sourceEnd: 1, targetStart: 1.0 / 30)])
    #expect(late.map { ($0 * 30).rounded() } == [1, 2, 3, 4])
    // Skipping the first packets drops them and moves the rest to the start.
    let trimmed = MediaSegment.playTimes(of: packets, segments: [MediaSegment(sourceStart: 2.0 / 30, sourceEnd: 1, targetStart: 0)])
    #expect(trimmed.map { ($0 * 30).rounded() } == [0, 1])
}
