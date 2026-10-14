import DiscCore
import Testing

@Suite struct VersionTests {
    @Test func reportsPinnedLibraryVersions() {
        let v = dc.libraryVersions()
        #expect(String(v.libdvdread) == "7.1.1")
        #expect(String(v.libdvdcss) == "1.6.0")
        #expect(String(v.libavformat).hasPrefix("63."))
    }

    @Test func rejectsPathThatIsNotADisc() {
        #expect(!dc.canOpenDisc(std.string("/nonexistent/disc.iso")))
    }
}
