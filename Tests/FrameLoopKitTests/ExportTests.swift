import Testing
@testable import FrameLoopKit

@Test func outputFramesAtSourceRate() {
    let result = ExportPlan.outputFrames(order: [3, 4, 5], durations: Array(repeating: 0.1, count: 10), speed: 1, fps: 10)
    #expect(result == [3, 4, 5])
}

@Test func outputFramesSlowMotionRepeats() {
    let result = ExportPlan.outputFrames(order: [0, 1], durations: [0.1, 0.1], speed: 0.5, fps: 10)
    #expect(result == [0, 0, 1, 1])
}

@Test func outputFramesResampleDown() {
    let result = ExportPlan.outputFrames(order: [0, 1, 2, 3], durations: Array(repeating: 0.1, count: 4), speed: 1, fps: 5)
    #expect(result == [0, 2])
}

@Test func letterboxFitsAndCentres() {
    let box = ExportPlan.letterbox(sourceWidth: 1920, sourceHeight: 1080, frameWidth: 768, frameHeight: 512)
    #expect(box.width == 768 && box.height == 432)
    #expect(box.x == 0 && box.y == 40)
    #expect(box.width % 2 == 0 && box.height % 2 == 0)
}

@Test func originalSizeKeepsThePictureAndStaysEven() {
    #expect(ExportPlan.evenSize(width: 1921, height: 1081) == (1920, 1080))
    #expect(ExportPlan.evenSize(width: 640, height: 360) == (640, 360))
    #expect(ExportPlan.bitrate(width: 640, height: 360) == 8_000_000)
    #expect(ExportPlan.bitrate(width: 1920, height: 1080) == 13_747_968)
    #expect(ExportPlan.bitrate(width: 7680, height: 4320) == 55_000_000)
}

@Test func fasterSpeedsShortenTheOutput() {
    let result = ExportPlan.outputFrames(order: [0, 1, 2, 3], durations: Array(repeating: 0.1, count: 4), speed: 2, fps: 10)
    #expect(result == [0, 2])
}

@Test func gifNeverGrows() {
    #expect(ExportPlan.gifSize(sourceWidth: 1920, sourceHeight: 1080, maxWidth: 640) == (640, 360))
    #expect(ExportPlan.gifSize(sourceWidth: 320, sourceHeight: 240, maxWidth: 640) == (320, 240))
}

private let tenFrames = (0..<10).map { FrameInfo(index: $0, pts: Double($0) * 0.1, duration: 0.1) }

private func matches(_ run: AudioRun, _ start: Double, _ end: Double, reversed: Bool) -> Bool {
    abs(run.start - start) < 1e-9 && abs(run.end - end) < 1e-9 && run.reversed == reversed
}

@Test func audioRunsForwardIsOneRun() {
    let runs = ExportPlan.audioRuns(order: [2, 3, 4, 5], frames: tenFrames)
    #expect(runs.count == 1 && matches(runs[0], 0.2, 0.6, reversed: false))
}

@Test func audioRunsPingPongGoesForwardThenBack() {
    let runs = ExportPlan.audioRuns(order: Timeline.pingPongOrder([2, 3, 4, 5, 6]), frames: tenFrames)
    #expect(runs.count == 2)
    #expect(matches(runs[0], 0.2, 0.7, reversed: false))
    #expect(matches(runs[1], 0.3, 0.6, reversed: true))
}

@Test func audioRunsWrappedSegmentSplitsAtTheJump() {
    let runs = ExportPlan.audioRuns(order: [8, 9, 0, 1], frames: tenFrames)
    #expect(runs.count == 2)
    #expect(matches(runs[0], 0.8, 1.0, reversed: false))
    #expect(matches(runs[1], 0.0, 0.2, reversed: false))
}
