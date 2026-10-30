import Testing
@testable import FrameLoop2Kit

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

@Test func gifNeverGrows() {
    #expect(ExportPlan.gifSize(sourceWidth: 1920, sourceHeight: 1080, maxWidth: 640) == (640, 360))
    #expect(ExportPlan.gifSize(sourceWidth: 320, sourceHeight: 240, maxWidth: 640) == (320, 240))
}
