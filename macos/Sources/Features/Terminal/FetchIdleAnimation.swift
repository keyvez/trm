import SwiftUI

/// The idle fidget: an ASCII dog that has brought the frisbee back and keeps
/// nudging it toward you, waiting for the next throw.
///
/// It fills the one state a status board cannot say with a colour — "this pane
/// is finished and waiting on you". A spinner would be exactly wrong: nothing
/// is in flight, so a progress shape would be a lie. What is wanted is the
/// posture of expectancy, which is why the dog pushes the disc a little closer
/// rather than just sitting there.
///
/// Every frame is the same number of columns and rows, so a row never reflows
/// as it plays; all the motion happens inside the fixed block.
struct FetchIdleAnimation: View {

    /// Seconds per frame. Slow enough to read as a fidget rather than a
    /// spinner — the point being made is patience, not progress.
    private static let frameDuration: TimeInterval = 0.16

    /// The dog, drawn once. `E` is an eye, `MM` the mouth and `T` the tail;
    /// each is replaced by something of exactly its own width, so no frame can
    /// be a different size from any other.
    private static let base: [String] = [
        "      ___          ___      ",
        "     /   \\________/   \\     ",
        "    |                  |    ",
        "    |   E          E   |    ",
        "    |        /\\        |    ",
        "     \\      ( MM )    /     ",
        "      \\______________/      ",
        "         |        |         ",
        "        (_)      (_)   T    ",
    ]

    /// Columns in a frame, including the frisbee line appended below the dog.
    private static let columns = 28
    /// Rows in a frame: the dog, plus the ground the frisbee sits on.
    private static var rows: Int { base.count + 1 }

    /// How far the frisbee sits from the left, frame by frame: three nudges
    /// toward you, then drawn back to start again. The long run at the top of
    /// the loop is the beat where the dog looks up and waits.
    private static let gaps = [12, 12, 12, 12, 10, 8, 8, 8, 10, 12, 12, 12, 12, 12, 12, 12]

    /// The frame where the eyes shut. One blink per loop, deliberately off the
    /// beat of the nudge so the two never read as a single twitch.
    private static let blinkFrames: Set<Int> = [7]

    /// Frames with the tongue out. Panting, twice a loop, and never during the
    /// blink — a dog that shuts its eyes and lolls at once reads as asleep,
    /// which is the opposite of the point.
    private static let pantFrames: Set<Int> = [4, 5, 12, 13]

    /// The height the block should fill. The type is sized from it rather than
    /// scaled down to fit, so the dog actually occupies the space it is given
    /// instead of floating in the middle of it.
    var height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // 0.78 of the row height is about where a monospaced face stops
        // overlapping its own neighbours; the rest is the leading.
        .font(.system(size: height / CGFloat(Self.rows) * 0.78, design: .monospaced))
        .lineSpacing(0)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        // Never let a narrow pane reflow the drawing into nonsense.
        .fixedSize(horizontal: true, vertical: false)
        .minimumScaleFactor(0.4)
        .accessibilityHidden(true)
        .help("Finished and waiting — throw it another one")
    }

    /// One frame of the loop, always the same number of rows and columns.
    static func frame(at index: Int) -> String {
        let step = index % gaps.count
        let eye = blinkFrames.contains(step) ? "-" : "o"
        let mouth = pantFrames.contains(step) ? "ww" : ".."
        var lines = base.map {
            $0.replacingOccurrences(of: "E", with: eye)
                .replacingOccurrences(of: "MM", with: mouth)
                .replacingOccurrences(of: "T", with: pantFrames.contains(step) ? "-" : "~")
        }
        let gap = gaps[step]
        let frisbee = String(repeating: " ", count: gap) + "(_)"
        lines.append(frisbee.padding(toLength: columns, withPad: " ", startingAt: 0))
        return lines.joined(separator: "\n")
    }

    /// Frames run off the wall clock rather than a per-view start date, so
    /// every idle row on the board fidgets in step. Out of phase they read as
    /// noise; in phase they read as one deliberate thing the board is doing.
    private static func frameIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / frameDuration)
    }
}
