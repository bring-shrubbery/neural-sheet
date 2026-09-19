import Testing

@testable import NeuralSheetCore

@Test func versionCompareStripsTheLeadingV() {
    #expect(VersionCompare.isNewer("v2.1", than: "2.0.9"))
    #expect(VersionCompare.isNewer("2.0.1", than: "v2"))
    #expect(VersionCompare.isNewer("V3.0", than: "v2.9.9"))
    #expect(!VersionCompare.isNewer("v1.0", than: "V1.0"))
}

@Test func versionCompareTreatsMissingComponentsAsZero() {
    #expect(!VersionCompare.isNewer("2.0", than: "2.0.0"))
    #expect(!VersionCompare.isNewer("2.0.0", than: "2.0"))
    #expect(VersionCompare.isNewer("2.0.1", than: "2"))
    #expect(!VersionCompare.isNewer("2", than: "2.0.1"))
}

@Test func versionCompareIsNumericNotLexicographic() {
    #expect(VersionCompare.isNewer("1.10.0", than: "1.9.0"))
    #expect(!VersionCompare.isNewer("1.9.0", than: "1.10.0"))
    #expect(VersionCompare.isNewer("10.0", than: "9.9"))
}

@Test func versionCompareIsFalseForTheSameOrOlderVersion() {
    #expect(!VersionCompare.isNewer("2.1.0", than: "2.1.0"))
    #expect(!VersionCompare.isNewer("2.0.9", than: "v2.1"))
    #expect(!VersionCompare.isNewer("1.0.0", than: "2.0.0"))
}

@Test func versionCompareTreatsEmptyAndUnparseableComponentsAsZero() {
    #expect(!VersionCompare.isNewer("", than: "0.0.0"))
    #expect(!VersionCompare.isNewer("v", than: ""))
    #expect(VersionCompare.isNewer("1.0", than: ""))
    #expect(!VersionCompare.isNewer("not.a.version", than: "0.0.1"))
}
