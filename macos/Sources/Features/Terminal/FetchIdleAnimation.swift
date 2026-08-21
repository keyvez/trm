import SwiftUI

/// The idle fidget: a small ASCII dog that has brought the frisbee back and is
/// nudging it toward you, waiting for the next throw.
///
/// It marks the one state a status board cannot say with a colour — "this pane
/// is finished and waiting on you". A spinner would be exactly wrong: nothing
/// is in flight, so a progress shape would be a lie. What is wanted is the
/// posture of expectancy, which is why the dog pushes the disc a little closer
/// rather than just sitting there.
///
/// Drawn in block glyphs rather than slashes and underscores. Line art needs
/// size to read, and this has none to spare — it lives *behind the reply box*,
/// where the row's own words and the draft you are typing both come first.
/// Solid shapes hold their form at eight points; `/\_|` turn to noise.
///
/// Every frame is the same number of rows and columns, so nothing shifts under
/// the text as it plays.
struct FetchIdleAnimation: View {

    /// Seconds per frame. Slow enough to read as a fidget rather than a
    /// spinner — the point being made is patience, not progress.
    private static let frameDuration: TimeInterval = 0.18

    /// Total columns in a frame; the dog occupies the last `dogWidth` of them
    /// and the frisbee travels the rest.
    private static let columns = 14
    private static let dogWidth = 5

    /// Where the frisbee sits, frame by frame: nudged toward you, then drawn
    /// back to start again. The run at each end is the beat where the dog
    /// holds still and waits.
    private static let gaps = [7, 7, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 2, 4, 6, 7]

    /// The frame where the eyes shut. One blink per loop, off the beat of the
    /// nudge so the two never read as a single twitch.
    private static let blinkFrames: Set<Int> = [10]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Point size of the glyphs. Small by default: this sits under live text.
    var size: CGFloat = 9

    var body: some View {
        Group {
            if reduceMotion {
                // Still the dog and the frisbee, just no fidget.
                Text(Self.frame(at: 0))
            } else {
                TimelineView(.periodic(from: .now, by: Self.frameDuration)) { context in
                    Text(Self.frame(at: Self.frameIndex(at: context.date)))
                }
            }
        }
        .font(.system(size: size, design: .monospaced))
        .lineSpacing(0)
        // Faint enough that a draft reads over it without a fight — it is
        // decoration behind an input, not a thing to look at.
        .foregroundStyle(.quaternary)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One frame, always the same number of rows and columns.
    ///
    /// `▟▀▀▀▙ / ▌●▪●▐ / ▜▄▄▄▛` is the dog head-on — brow, two eyes either side
    /// of the nose, jaw — and `●` is the frisbee it keeps pushing your way.
    static func frame(at index: Int) -> String {
        let step = index % gaps.count
        let eye = blinkFrames.contains(step) ? "▬" : "●"
        let rows = ["▟▀▀▀▙", "▌\(eye)▪\(eye)▐", "▜▄▄▄▛"]
        let gap = gaps[step]
        return rows.enumerated().map { offset, row in
            var lead = Array(repeating: Character(" "), count: columns - dogWidth)
            // The frisbee rides the middle line, level with the dog's eyes.
            if offset == 1, gap < lead.count { lead[gap] = "●" }
            return String(lead) + row
        }.joined(separator: "\n")
    }

    /// Frames run off the wall clock rather than a per-view start date, so
    /// every idle row on the board fidgets in step. Out of phase they read as
    /// noise; in phase they read as one deliberate thing the board is doing.
    private static func frameIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / frameDuration)
    }
}
