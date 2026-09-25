import Testing
@testable import trm

/// A default letter is not a name, and the name store must not treat it as one.
struct WatermarkStoreTests {
    @Test func aDefaultLetterIsAPlaceholder() {
        #expect(ZmxSessionManager.isPlaceholderWatermark("S"))
        #expect(ZmxSessionManager.isPlaceholderWatermark(" Z "))
    }

    @Test func aChosenNameIsNot() {
        #expect(!ZmxSessionManager.isPlaceholderWatermark("fasmac"))
        #expect(!ZmxSessionManager.isPlaceholderWatermark("s"))
        #expect(!ZmxSessionManager.isPlaceholderWatermark("⑂ resume-prefill"))
        #expect(!ZmxSessionManager.isPlaceholderWatermark("AB"))
        #expect(!ZmxSessionManager.isPlaceholderWatermark(""))
    }
}
