import Foundation

extension WindowLibrary {
    /// setFlaggedLayout sets the app-wide flagged layout on the library and every open store.
    public func setFlaggedLayout(_ layout: FlaggedViewLayout) {
        flaggedLayout = layout
        for store in stores.values { store.flaggedLayout = layout }
    }
}
