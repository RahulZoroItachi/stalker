import Foundation
import StalkerCore

/// Tests for hand-logged activities: span arithmetic, the notes file, resolution
/// against recorded time, and the reporting that follows.

@MainActor func spanTests(_ t: T) {
    // --- normalized: one canonical form for any set of spans ---
    t.eq(normalized([]), [], "an empty set normalizes to empty")
    t.eq(normalized([Span(10, 20)]), [Span(10, 20)], "a single span is unchanged")
    t.eq(normalized([Span(30, 40), Span(10, 20)]), [Span(10, 20), Span(30, 40)],
         "spans come back sorted by start")
    t.eq(normalized([Span(10, 20), Span(15, 30)]), [Span(10, 30)], "overlapping spans merge")
    // Touching spans merge too. Leaving [10,20) and [20,30) separate would make the
    // arithmetic depend on how the input happened to be split.
    t.eq(normalized([Span(10, 20), Span(20, 30)]), [Span(10, 30)], "touching spans merge")
    t.eq(normalized([Span(10, 20), Span(25, 30)]), [Span(10, 20), Span(25, 30)],
         "spans with a hole between them stay separate")
    t.eq(normalized([Span(10, 10)]), [], "an empty span is dropped")
    t.eq(normalized([Span(20, 10)]), [], "a backwards span is dropped rather than negated")
    t.eq(normalized([Span(10, 50), Span(20, 30)]), [Span(10, 50)],
         "a span wholly inside another is absorbed")

    // --- totalSeconds ---
    t.eq(totalSeconds([]), 0, "nothing is zero seconds")
    t.eq(totalSeconds([Span(0, 60), Span(120, 180)]), 120, "disjoint spans sum")
    // Counted after normalising, so double-counting an overlap is impossible.
    t.eq(totalSeconds([Span(0, 60), Span(30, 90)]), 90, "an overlap is counted once")

    // --- subtracting ---
    t.eq(subtracting([Span(0, 100)], []), [Span(0, 100)], "subtracting nothing changes nothing")
    t.eq(subtracting([Span(0, 100)], [Span(200, 300)]), [Span(0, 100)],
         "subtracting a disjoint span changes nothing")
    t.eq(subtracting([Span(0, 100)], [Span(0, 100)]), [], "subtracting itself leaves nothing")
    t.eq(subtracting([Span(0, 100)], [Span(0, 200)]), [], "a larger cut leaves nothing")
    t.eq(subtracting([Span(0, 100)], [Span(0, 40)]), [Span(40, 100)], "a cut at the start")
    t.eq(subtracting([Span(0, 100)], [Span(60, 100)]), [Span(0, 60)], "a cut at the end")
    // The case the whole feature rests on: 40 minutes of Slack in the middle of a
    // seven-hour sleep leaves sleep on both sides of it, not one side.
    t.eq(subtracting([Span(0, 100)], [Span(40, 60)]), [Span(0, 40), Span(60, 100)],
         "a cut in the middle splits the span in two")
    t.eq(subtracting([Span(0, 100)], [Span(10, 20), Span(30, 40)]),
         [Span(0, 10), Span(20, 30), Span(40, 100)], "two cuts leave three pieces")
    t.eq(subtracting([Span(0, 50), Span(100, 150)], [Span(25, 125)]),
         [Span(0, 25), Span(125, 150)], "one cut can span the hole between two spans")

    // --- intersecting ---
    t.eq(intersecting([Span(0, 100)], [Span(40, 60)]), [Span(40, 60)], "the inner span survives")
    t.eq(intersecting([Span(0, 100)], [Span(200, 300)]), [], "disjoint spans intersect to nothing")
    t.eq(intersecting([Span(0, 100)], []), [], "intersecting with nothing yields nothing")
    t.eq(intersecting([Span(0, 50), Span(100, 150)], [Span(25, 125)]),
         [Span(25, 50), Span(100, 125)], "an intersection can produce several pieces")
    t.eq(intersecting([Span(0, 100)], [Span(0, 100)]), [Span(0, 100)], "identical spans intersect whole")

    // --- clippedTo, the day-boundary helper ---
    t.eq(clipped([Span(0, 100)], to: Span(20, 80)), [Span(20, 80)], "a span is clipped to the window")
    t.eq(clipped([Span(0, 10)], to: Span(20, 80)), [], "a span outside the window disappears")
    // A note crossing midnight has to contribute to each day separately, which is
    // exactly this clip applied twice with different windows.
    t.eq(clipped([Span(50, 150)], to: Span(0, 100)), [Span(50, 100)],
         "the first day gets the part before the boundary")
    t.eq(clipped([Span(50, 150)], to: Span(100, 200)), [Span(100, 150)],
         "the second day gets the part after it")
}
