import ActivityKit
import SwiftUI
import WidgetKit

/// One cell in the Custom layout's value row: an icon, the number, and a
/// caption under it.
struct LiveActivityCustomTile: View {
    let symbol: String
    let value: String
    let caption: String
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The Custom layout's value row: three cells across the full banner width,
/// separated by hairlines.
///
/// Device health is not here — it lives in the header pills, so every cell in
/// this row follows one format (icon, value, caption) with no split variants or
/// alert backgrounds. That uniformity is the point: the row reads as a list of
/// numbers rather than as three different kinds of thing. State that isn't a
/// number — suspension, a hand-set rate — is carried by the basal cell's colour
/// and icon rather than by a fourth visual treatment.
struct LiveActivityCustomTilesView: View {
    let iob: Decimal
    let cob: Decimal
    let basal: LiveActivityAttributes.BasalStatus?

    private static let decimals: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// Three fraction digits, matching the home screen's basal tag.
    private static let basalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    private func number(_ value: Decimal) -> String {
        Self.decimals.string(from: value as NSNumber) ?? "--"
    }

    var body: some View {
        HStack(spacing: 0) {
            LiveActivityCustomTile(
                symbol: "syringe.fill",
                value: number(iob) + " " + String(localized: "U", comment: "Insulin unit"),
                caption: String(localized: "IOB", comment: "Insulin on board, Custom Live Activity tile"),
                tint: LiveActivityCustomPalette.insulin
            )

            hairline

            LiveActivityCustomTile(
                symbol: "fork.knife",
                value: number(cob) + " " + String(localized: "g", comment: "gram of carbs"),
                caption: String(localized: "COB", comment: "Carbs on board, Custom Live Activity tile"),
                tint: LiveActivityCustomPalette.carbs
            )

            hairline

            basalTile
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 26)
    }

    /// Suspension takes the cell. Otherwise the rate, tinted amber with a raised
    /// hand when it was set by hand rather than by the algorithm — the same
    /// distinction the home screen's basal tag draws, carried by colour and
    /// icon instead of by the filled/outlined capsule this row has no room for.
    @ViewBuilder private var basalTile: some View {
        if let basal {
            if basal.isSuspended {
                LiveActivityCustomTile(
                    symbol: "pause.circle.fill",
                    value: String(localized: "Suspended", comment: "Pump has suspended insulin delivery"),
                    caption: String(localized: "Basal", comment: "Basal tile caption, Custom Live Activity"),
                    tint: LiveActivityCustomPalette.red
                )
            } else {
                let rate = basal.rate.map { Self.basalFormatter.string(from: $0 as NSNumber) ?? "--" } ?? "--"
                let isManual = basal.kind == .manualTemp
                LiveActivityCustomTile(
                    symbol: isManual ? "hand.raised.fill" : "drop.fill",
                    value: rate + " " + String(localized: "U/hr", comment: "Insulin units per hour"),
                    caption: String(localized: "Basal", comment: "Basal tile caption, Custom Live Activity"),
                    tint: isManual ? LiveActivityCustomPalette.yellow : LiveActivityCustomPalette.insulin
                )
            }
        } else {
            LiveActivityCustomTile(
                symbol: "drop.fill",
                value: "--",
                caption: String(localized: "Basal", comment: "Basal tile caption, Custom Live Activity"),
                tint: .secondary
            )
        }
    }
}
