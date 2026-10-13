import Foundation

extension SettingsDefaults {
    /// ユーザー指定の標準値。起動時の登録と初期化で共用する。
    static let shared = SettingsDefaults(applicationFields: [
        Field(key: ShelfDirection.storageKey, initial: .bool(true)),
        Field(key: ShelfDirection.snapStorageKey, initial: .bool(true)),
        Field(key: MagazineShelfLayout.twoColumnsKey, initial: .bool(false)),
        Field(key: MagazineLogoBackground.transparencyKey, initial: .number(MagazineLogoBackground.defaultTransparency)),
        Field(key: TabBarStyle.styleKey, initial: .text(TabBarStyle.glass)),
        Field(key: TabBarStyle.iPadBottomKey, initial: .bool(false)),
        Field(key: ControlsPosition.key, initial: .bool(false)),
        Field(key: KeyboardFocus.onOpenSearchKey, initial: .bool(false)),
        Field(key: KeyboardFocus.onReselectKey, initial: .bool(false)),
        Field(key: ImageCache.memoryLimitKey, initial: .number(Double(ImageCache.defaultMemoryMB))),
        Field(key: ImageCache.diskLimitKey, initial: .number(Double(ImageCache.defaultDiskMB))),
        Field(key: CommentPostButtonSettings.onLeftKey, initial: .bool(false))
    ], readerFields: [
        Field(key: ReaderImageQuality.key, initial: .text(ReaderImageQuality.high.rawValue)),
        Field(key: NativeReaderSettings.autoplayKey, initial: .number(6)),
        Field(key: NativeReaderSettings.endPageKey, initial: .bool(true)),
        Field(key: ReaderTapMode.key, initial: .text(ReaderTapMode.leftForward.rawValue)),
        Field(key: ReaderTapMode.animationKey, initial: .bool(true)),
        Field(key: ReaderGlassStyle.key, initial: .bool(true)),
        Field(key: NativeReaderSettings.hideBarsOnTurnKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.showsBarsOnOpenKey, initial: .bool(false)),
        Field(key: NativeReaderSettings.magazineLogoKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.indexAnimationKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.swipeUpIndexKey, initial: .bool(false)),
        Field(key: NativeReaderSettings.entranceAnimationKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.autoplayStyleKey, initial: .text("bar")),
        Field(key: NativeReaderSettings.autoplayBelowImageKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.autoplayStopsOnNavigationKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.autoplayResumesAfterNavigationKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.autoplayContinuesOnLayoutChangeKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.pageProgressKey, initial: .bool(true)),
        Field(key: NativeReaderSettings.verticalPageProgressKey, initial: .bool(false)),
        Field(key: NativeReaderSettings.verticalNavigationHorizontalProgressKey, initial: .bool(true)),
        Field(key: NativeReadingLayout.verticalSwipeKey, initial: .bool(false)),
        Field(key: NativeReaderSettings.progressOnLeftKey, initial: .bool(false)),
        Field(key: NativeReaderSettings.previousHintPositionKey, initial: .number(0)),
        Field(key: NativeReaderSettings.previousHintTravelKey, initial: .number(48)),
        Field(key: NativeReadingLayout.key, initial: .text(NativeReadingLayout.horizontal.rawValue)),
        Field(key: ReaderSpreadMode.key, initial: .number(Double(ReaderSpreadMode.initial.rawValue))),
        Field(key: ReaderSpreadOrientation.key, initial: .text(ReaderSpreadOrientation.landscape.rawValue)),
        Field(key: ReaderSpreadOrientation.phoneKey, initial: .bool(false)),
        Field(key: CommentPostButtonSettings.onLeftKey, initial: .bool(false)),
        Field(key: ReaderAppSetting.showsStatusBarKey, initial: .bool(true)),
        Field(key: ReaderMode.indexSnapsKey, initial: .bool(true))
    ])
}
