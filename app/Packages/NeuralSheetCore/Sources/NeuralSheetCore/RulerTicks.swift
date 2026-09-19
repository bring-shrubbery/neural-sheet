/// Where the time ruler puts its ticks.
public enum RulerTicks {
    /// The spacings that read as round numbers of seconds. Anything between them would put labels
    /// at times nobody thinks in.
    public static let divisions: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60]

    /// The narrowest spacing a `m:ss` label still fits in.
    public static let minLabelGap = 56.0

    /// The first division whose pixel spacing reaches the label gap, or the widest one when the
    /// view is zoomed so far out that even a minute is too narrow to label.
    public static func division(pixelsPerSecond: Double) -> Double {
        for division in divisions where division * pixelsPerSecond >= minLabelGap {
            return division
        }

        return divisions[divisions.count - 1]
    }
}
