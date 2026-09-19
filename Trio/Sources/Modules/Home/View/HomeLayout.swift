import CoreGraphics

/// Fixed zone heights for the non-scrolling Home dashboard; the chart takes the remainder.
enum HomeLayout {
    /// header slot: loop/evBG pills / glucose bobble / IOB-COB pills.
    ///
    /// Upstream is 172 because its sensor status tag overhangs the bobble. This
    /// layout moved that tag onto the CGM device lane (2026-09-08), so the room
    /// reserved for it became dead air between the bobble and the lanes — the
    /// gap below the lanes is a deliberate `deviceLanesGap`, but the gap above
    /// them is only ever whatever slack is left in this fixed slot, so the two
    /// stopped matching. 154 leaves 24pt around the 130pt bobble.
    ///
    /// Still a fixed slot on purpose: header state changes must never reflow the
    /// zones below. It also feeds the chart's height in `HomeRootView`, so the
    /// 18pt freed here goes to the chart. On merge, keep this value — upstream's
    /// 172 is correct for upstream and wrong here.
    static let headerHeight: CGFloat = 154
    /// device session lanes (CGM + pump), each on its own glass card, sitting
    /// above the chart; replaces the bobble sensor arc and standalone pump panel
    static let deviceLanesHeight: CGFloat = 62
    /// clear air between the device lanes and the top of the chart
    static let deviceLanesGap: CGFloat = 16
    /// meal panel slot (IOB / COB / delivery rate)
    static let mealSlotHeight: CGFloat = 44
    /// shared slot for adjustment panel and bolus progress (was 8% of screen height)
    static let bottomPanelHeight: CGFloat = 60
    /// stats banner slot below the adjustment panel (multi-use panel later)
    static let statsBannerHeight: CGFloat = 60
    /// clear air above, between, and below the bottom-zone panels
    static let bottomZonePadding: CGFloat = 10
    static var bottomZoneHeight: CGFloat { bottomPanelHeight + statsBannerHeight + 3 * bottomZonePadding }
    /// pull distance that triggers the forced loop
    static let refreshTriggerDistance: CGFloat = 70
    /// indicator row height while the loop runs
    static let refreshIndicatorHeight: CGFloat = 40
    /// last-resort chart floor; must stay below the tightest natural allocation
    /// (SE under the iOS 26 tab bar + accessory leaves ~140) or the bottom zone overflows
    static let chartMinHeight: CGFloat = 130
}
