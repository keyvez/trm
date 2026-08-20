import SwiftUI

/// The idle fidget: a small ASCII dog that has brought the frisbee back and
/// keeps nudging it toward you, waiting for the next throw.
///
/// It marks the one state a status board cannot say with a colour — "this
/// pane is finished and waiting on you". A spinner would be exactly wrong
/// here: nothing is in flight, so a progress shape would be a lie. What is
/// wanted is the posture of *expectancy*, which is why the dog pushes the
/// disc a little closer rather than just sitting there.
///
/// Every frame is the same number of columns, so a row never reflows as it
/// plays; all the motion happens inside a fixed 11-character box.
struct FetchIdleAnimation: View {

    /// Seconds per frame. Slow enough to read as a fidget rather than a
    /// spinner — the point being made is patience, not progress.
    private static let frameDuration: TimeInterval = 0.16

    /// How far the frisbee sits from the dog, frame by frame: three nudges
    /// closer to you, then drawn back to start again. The long run of `3` at
    /// the top of the loop is the beat where the dog looks up and waits.
    private static let gaps = [3, 3, 3, 3, 2, 1, 1, 1, 2, 3, 3, 3, 3, 3, 3, 3]

    /// The frame where the eyes shut. One blink per loop, deliberately off
    /// the beat of the nudge so the two never read as a single twitch.
    private static let blinkFrames: Set<Int> = [7]

    /// Frames where the tongue is out. Panting, twice a loop, and never
    /// during the blink — a dog that shuts its eyes and lolls at the same
    /// time reads as asleep, which is the opposite of the point.
    private static let pantFrames: Set<Int> = [4, 5, 12, 13]

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
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.tertiary)
        // Decorative on its own; the row's status label already says "idle".
        .accessibilityHidden(true)
        .help("Finished and waiting — throw it another one")
    }

    /// One frame of the loop, always 11 columns wide.
    ///
    /// `U^.^U` is the dog head-on — the `U`s are ears — and `(_)` is the
    /// frisbee lying in front of it. The gap between them is the animation.
    static func frame(at index: Int) -> String {
        let step = index % gaps.count
        let eye = blinkFrames.contains(step) ? "-" : "^"
        let mouth = pantFrames.contains(step) ? "w" : "."
        let gap = gaps[step]
        let lead = String(repeating: " ", count: gap)
        let trail = String(repeating: " ", count: gaps[0] - gap)
        return "U\(eye)\(mouth)\(eye)U" + lead + "(_)" + trail
    }

    /// Frames run off the wall clock rather than a per-view start date, so
    /// every idle row on the board fidgets in step. Out of phase they read as
    /// noise; in phase they read as one deliberate thing the board is doing.
    private static func frameIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / frameDuration)
    }
}
