import Testing

@testable import NeuralSheetCore

@Test func transportFormatsMinutesSecondsHundredths() {
    #expect(TimeFormat.transport(61.239) == "01:01.23")
    #expect(TimeFormat.transport(0) == "00:00.00")
    #expect(TimeFormat.transport(-1) == "00:00.00")
    #expect(TimeFormat.transport(599.99) == "09:59.99")
    #expect(TimeFormat.transportPlaceholder == "--:--.--")
}

@Test func transportDoesNotLoseAHundredthToBinaryScaling() {
    // 0.29 * 100 == 28.999999999999996 and 1.15 * 100 == 114.99999999999999 in binary64.
    #expect(TimeFormat.transport(0.29) == "00:00.29")
    #expect(TimeFormat.transport(1.15) == "00:01.15")
    #expect(TimeFormat.transport(60.29) == "01:00.29")
    // Genuine fractions still truncate rather than round up.
    #expect(TimeFormat.transport(2.675) == "00:02.67")
    #expect(TimeFormat.transport(0.999) == "00:00.99")
}

@Test func rulerFormatsMinutesAndPaddedSeconds() {
    #expect(TimeFormat.ruler(65) == "1:05")
    #expect(TimeFormat.ruler(0) == "0:00")
    #expect(TimeFormat.ruler(125.9) == "2:05")
}

@Test func decibelsHaveOneDecimal() {
    #expect(TimeFormat.decibels(-3) == "-3.0")
    #expect(TimeFormat.decibels(0) == "0.0")
    #expect(TimeFormat.decibels(-12.34) == "-12.3")
}

@Test func secondsUseTwoDecimals() {
    #expect(TimeFormat.seconds2(12.34) == "12.34")
    #expect(TimeFormat.seconds2(0) == "0.00")
}

@Test func fileSizeUsesGigabytesAboveOneBillionBytes() {
    #expect(TimeFormat.fileSize(bytes: 618_442_496) == "618 MB")
    #expect(TimeFormat.fileSize(bytes: 2_739_142_176) == "2.7 GB")
    #expect(TimeFormat.fileSize(bytes: 1_000_000_000) == "1.0 GB")
    #expect(TimeFormat.fileSize(bytes: 999_999_999) == "1000 MB")
}

@Test func pitchNamesUseMiddleCFour() {
    #expect(TimeFormat.pitchName(60) == "C4")
    #expect(TimeFormat.pitchName(36) == "C2")
    #expect(TimeFormat.pitchName(79) == "G5")
    #expect(TimeFormat.pitchName(80) == "G#5")
    #expect(TimeFormat.pitchName(0) == "C-1")
}
