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

    @Test func hoverLiftRespectsMotionAndControlState() {
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        for theme in DockThemeID.allCases {
            DockThemeRuntime.current = theme
            for disabled in [false, true] {
                for pressed in [false, true] {
                    for reduced in [false, true] {
                        let offset = DockMotion.hoverOffset(
                            isHovered: true, isPressed: pressed, isEnabled: !disabled, reduceMotion: reduced)
                        if disabled || pressed || reduced || !theme.style.animates {
                            #expect(offset == 0)
                        } else {
                            #expect(offset >= -1.5 && offset <= 0)
                        }
                    }
                }
            }
            #expect(
                DockMotion.hoverOffset(
                    isHovered: false, isPressed: false, isEnabled: true, reduceMotion: false) == 0)
        }
        DockThemeRuntime.current = .glass
        #expect(
            DockMotion.hoverOffset(
                isHovered: true, isPressed: false, isEnabled: true, reduceMotion: false) == -1)
        DockThemeRuntime.current = .clay
        #expect(
            DockMotion.hoverOffset(
                isHovered: true, isPressed: false, isEnabled: true, reduceMotion: false) == -1.5)
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
