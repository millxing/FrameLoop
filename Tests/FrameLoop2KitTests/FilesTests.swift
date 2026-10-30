import Foundation
import Testing
@testable import FrameLoop2Kit

@Test func counterSkipsExistingFiles() {
    let names = ["ss00000003.png", "ss00000007.png", "loop00000009.mp4", "notes.txt"]
    #expect(FileCounter.next(saved: 1, fileNames: names, prefix: "ss", ext: "png") == 8)
    #expect(FileCounter.next(saved: 20, fileNames: names, prefix: "ss", ext: "png") == 20)
    #expect(FileCounter.next(saved: 1, fileNames: [], prefix: "loop", ext: "mp4") == 1)
    #expect(FileCounter.fileName(prefix: "loop", counter: 12, ext: "gif") == "loop00000012.gif")
}

@Test func folderFilterKeepsVideosSorted() {
    let names = ["b.MOV", "A.mp4", "notes.txt", ".hidden.mp4", "c.mkv"]
    #expect(MediaFormats.filter(names) == ["A.mp4", "b.MOV", "c.mkv"])
}

@Test func nativeFormats() {
    #expect(MediaFormats.isNative(URL(fileURLWithPath: "/a/b.MP4")))
    #expect(!MediaFormats.isNative(URL(fileURLWithPath: "/a/b.mkv")))
    #expect(MediaFormats.isSupported(URL(fileURLWithPath: "/a/b.gif")))
    #expect(PlaybackSpeed.all == [2, 1.5, 1.25, 1, 0.75, 0.5, 0.25])
    #expect(PlaybackSpeed.label(1.25) == "1.25×" && PlaybackSpeed.label(1) == "1×")
}
