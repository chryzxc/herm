import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockMotionTests {
    @Test func reducedMotionOverridesEveryTheme() {
        for theme in DockThemeID.allCases {
            #expect(!DockMotion.isEnabled(reduceMotion: true, theme: theme))
            #expect(DockMotion.isEnabled(reduceMotion: false, theme: theme) == theme.style.animates)
        }
    }

    @Test func pressEffectsRespectDisabledControlsAndMotionPreferences() {
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        for theme in DockThemeID.allCases {
            DockThemeRuntime.current = theme
            #expect(DockMotion.pressScale(isPressed: false, isEnabled: true, reduceMotion: false) == 1)
            #expect(DockMotion.pressScale(isPressed: true, isEnabled: false, reduceMotion: false) == 1)
            #expect(DockMotion.pressScale(isPressed: true, isEnabled: true, reduceMotion: true) == 1)
            #expect(
                DockMotion.pressScale(isPressed: true, isEnabled: true, reduceMotion: false)
                    == (theme.style.animates ? theme.style.pressScale : 1))
            #expect(DockMotion.animation(reduceMotion: true) == nil)
            if !theme.style.animates {
                #expect(DockMotion.animation(reduceMotion: false) == nil)
                #expect(Animation.dockFeedback(true) == nil)
                #expect(Animation.dockFeedback(false) == nil)
            }
        }
    }
}
