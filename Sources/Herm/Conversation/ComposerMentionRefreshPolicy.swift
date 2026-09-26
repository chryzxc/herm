enum ComposerMentionRefreshPolicy {
    static func shouldRefresh(wasPickerVisible: Bool, isPickerVisible: Bool) -> Bool {
        isPickerVisible && !wasPickerVisible
    }
}
