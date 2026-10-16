import XCTest
@testable import MPVPlayerKit

final class MPVQuickPlayerSubtitlePreferencesTests: XCTestCase {
    func testLegacyRadiusMigratesOnceIntoSharedStyle() throws {
        let name = "MPVQuickPlayerSubtitlePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(7.5, forKey: "MPVQuickPlayer.subtitleShadowRadius")
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.style(defaults: defaults).shadowRadius, 7.5)
        XCTAssertNil(defaults.object(forKey: "MPVQuickPlayer.subtitleShadowRadius"))
        defaults.set(2, forKey: "MPVQuickPlayer.subtitleShadowRadius")
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.style(defaults: defaults).shadowRadius, 7.5)
    }

    func testSharedStyleRoundTripPreservesEveryExistingField() throws {
        let name = "MPVQuickPlayerSubtitlePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var style = MPVSubtitleStyle.highContrast
        style.fontName = "Test Font"
        style.bottomOffset = 50
        style.shadowRadius = 8
        MPVQuickPlayerSubtitlePreferences.save(style, defaults: defaults)
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.style(defaults: defaults), style)
    }

    func testControlsPersistIndependentlyWithoutSessionFields() throws {
        let name = "MPVQuickPlayerSubtitlePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let primary = MPVQuickPlayerSubtitlePreferences.control(in: .primary, defaults: defaults)
        let secondary = MPVQuickPlayerSubtitlePreferences.control(in: .secondary, defaults: defaults)
        XCTAssertEqual(primary.position, 100)
        XCTAssertEqual(secondary.position, 0)
        XCTAssertFalse(secondary.automatic)
        MPVQuickPlayerSubtitlePreferences.save(
            .init(position: 37, usesOriginalStyle: true, automatic: true, language: .english),
            in: .secondary, defaults: defaults
        )
        let restored = MPVQuickPlayerSubtitlePreferences.control(in: .secondary, defaults: defaults)
        XCTAssertEqual(restored.position, 37)
        XCTAssertTrue(restored.usesOriginalStyle)
        XCTAssertTrue(restored.automatic)
        XCTAssertEqual(restored.language, .english)
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.control(in: .primary, defaults: defaults).position, 100)
        let saved = try XCTUnwrap(defaults.dictionary(forKey: "MPVQuickPlayer.subtitle.1"))
        XCTAssertEqual(Set(saved.keys), ["position", "originalStyle", "automatic", "language"])
    }
}
