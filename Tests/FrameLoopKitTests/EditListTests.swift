import Testing
@testable import FrameLoopKit

private func list() -> EditList {
    EditList(pieces: [EditPiece(source: 0, start: 0, end: 10)])
}

@Test func removeMiddleSplitsThePiece() {
    var edits = list()
    edits.remove(from: 3, to: 5)
    #expect(edits.pieces == [EditPiece(source: 0, start: 0, end: 3), EditPiece(source: 0, start: 5, end: 10)])
    #expect(edits.duration == 8)
}

@Test func removeFromTheEdges() {
    var head = list()
    head.remove(from: 0, to: 4)
    #expect(head.pieces == [EditPiece(source: 0, start: 4, end: 10)])
    var tail = list()
    tail.remove(from: 6, to: 10)
    #expect(tail.pieces == [EditPiece(source: 0, start: 0, end: 6)])
}

@Test func removeEverythingLeavesNothing() {
    var edits = list()
    edits.remove(from: 0, to: 10)
    #expect(edits.pieces.isEmpty)
}

@Test func removeAcrossAnAppendedPiece() {
    var edits = list()
    edits.append(EditPiece(source: 1, start: 0, end: 4))
    edits.remove(from: 8, to: 12)
    #expect(edits.pieces == [EditPiece(source: 0, start: 0, end: 8), EditPiece(source: 1, start: 2, end: 4)])
}

@Test func laterCutsUseTimelineTime() {
    var edits = list()
    edits.remove(from: 1, to: 2)
    edits.remove(from: 1, to: 2)
    #expect(edits.pieces == [EditPiece(source: 0, start: 0, end: 1), EditPiece(source: 0, start: 3, end: 10)])
}

@Test func editedFramesKeepSpacingAcrossACut() {
    let source = (0..<10).map { FrameInfo(index: $0, pts: Double($0), duration: 1) }
    var edits = EditList(pieces: [EditPiece(source: 0, start: 0, end: 10)])
    edits.remove(from: 2.5, to: 6.5)   // between frames: removes frames 3...6
    let frames = edits.frames(sourceFrames: [source])
    #expect(frames.count == 6)
    #expect(frames.map(\.pts) == [0, 1, 2, 3, 4, 5])
    #expect(frames.map(\.index) == [0, 1, 2, 3, 4, 5])
}

@Test func editedFramesFollowAnAppendedClip() {
    let first = (0..<3).map { FrameInfo(index: $0, pts: Double($0), duration: 1) }
    let second = (0..<2).map { FrameInfo(index: $0, pts: Double($0) * 0.5, duration: 0.5) }
    var edits = EditList(pieces: [EditPiece(source: 0, start: 0, end: 3)])
    edits.append(EditPiece(source: 1, start: 0, end: 1))
    #expect(edits.frames(sourceFrames: [first, second]).map(\.pts) == [0, 1, 2, 3, 3.5])
}
