import SwiftUI

/// LOCAL: LOOP-CONTACT. The "Loop Status" contact image style: a phone icon coloured by
/// loop state over the time the loop last ran, like the watch's loop complication but drawn
/// by the phone, so it changes as soon as the loop finishes. Rendered by `ContactPicture` via
/// `ImageRenderer` at `Layout.nativeSize` and scaled up from there, as the Glucose Bobble is.
///
/// The colour comes from `LoopFreshness.bitmapColor`, the same classifier as the contact
/// image's loop ring and the Home loop pill, so all three always agree.
struct LoopStatusContactView: View {
    let freshness: LoopFreshness
    /// The last loop time ("07:25"), or nil if the loop has never run.
    let lastLoopText: String?

    enum Layout {
        static let nativeSize: CGFloat = 256
        // The image is shown cropped to a circle (contact photo, watch complication),
        // so the time, the widest piece, must sit high enough for the circle to be
        // wider than it. 104/54 put "09:51" almost on the edge (26 Nov preview); the
        // narrow phone icon can stay larger than the time, as it sits where the circle
        // is still wide enough for it.
        static let iconSize: CGFloat = 100
        static let timeSize: CGFloat = 46
        static let spacing: CGFloat = 6
        static let contentWidth: CGFloat = 170
    }

    /// The watch complication's choice: a struck-through phone once the loop is overdue.
    private var symbol: String {
        freshness == .stale ? "iphone.slash" : "iphone"
    }

    var body: some View {
        VStack(spacing: Layout.spacing) {
            Image(systemName: symbol)
                .font(.system(size: Layout.iconSize, weight: .semibold))
                .foregroundStyle(freshness.bitmapColor)

            Text(lastLoopText ?? "– –")
                .font(.system(size: Layout.timeSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: Layout.contentWidth)
        .frame(width: Layout.nativeSize, height: Layout.nativeSize)
    }
}
