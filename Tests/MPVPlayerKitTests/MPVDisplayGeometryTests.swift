import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVDisplayGeometryTests: XCTestCase {
    func testAspectFitMapsPortraitAndLandscapeWithoutRotation() {
        let canvas = CGSize(width: 852, height: 393)
        let portrait = CGRect(x: 0, y: 0, width: 393, height: 852)
        let landscape = CGRect(x: 0, y: 0, width: 852, height: 393)
        let portraitMapping = MPVDisplayGeometry.make(
            canvasSize: canvas,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: portrait,
            contentMode: .fit
        )
        let landscapeMapping = MPVDisplayGeometry.make(
            canvasSize: canvas,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: landscape,
            contentMode: .fit
        )

        XCTAssertEqual(portraitMapping.rotation, 0.0)
        XCTAssertEqual(landscapeMapping.rotation, 0.0)
        XCTAssertEqual(
            portraitMapping.targetVideoRect.width / portraitMapping.targetVideoRect.height,
            16.0 / 9.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            landscapeMapping.targetVideoRect.width / landscapeMapping.targetVideoRect.height,
            16.0 / 9.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            portraitMapping.scale,
            portraitMapping.targetVideoRect.height / portraitMapping.sourceVideoRect.height,
            accuracy: 0.001
        )
        XCTAssertEqual(landscapeMapping.scale, 1.0, accuracy: 0.001)
    }

    func testAspectFillCoversTargetWithVideoAspect() {
        let mapping = MPVDisplayGeometry.make(
            canvasSize: CGSize(width: 852, height: 393),
            videoAspectRatio: 2.35,
            targetBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
            contentMode: .fill
        )

        XCTAssertEqual(mapping.rotation, 0.0)
        XCTAssertEqual(
            mapping.targetVideoRect.width / mapping.targetVideoRect.height,
            2.35,
            accuracy: 0.001
        )
        XCTAssertEqual(
            mapping.targetVideoRect.width / mapping.targetVideoRect.height,
            mapping.sourceVideoRect.width / mapping.sourceVideoRect.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            mapping.scale,
            mapping.targetVideoRect.width / mapping.sourceVideoRect.width,
            accuracy: 0.001
        )
        // Cover the visible target — no top/bottom letterbox bars.
        XCTAssertGreaterThanOrEqual(mapping.targetVideoRect.width, 393.0)
        XCTAssertGreaterThanOrEqual(mapping.targetVideoRect.height, 852.0)
    }

    func testCustomScaleUsesFillCoverWithoutLetterbox() {
        let targetBounds = CGRect(x: 0, y: 0, width: 852, height: 393)
        let fillMapping = MPVDisplayGeometry.make(
            canvasSize: targetBounds.size,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: targetBounds,
            contentMode: .fill
        )
        let customMapping = MPVDisplayGeometry.make(
            canvasSize: targetBounds.size,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: targetBounds,
            contentMode: .custom(scale: 1.5)
        )

        // Custom shares fill's cover mapping so 100% custom has no black bars.
        XCTAssertEqual(customMapping.targetVideoRect, fillMapping.targetVideoRect)
        XCTAssertEqual(customMapping.scale, fillMapping.scale, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(customMapping.targetVideoRect.width, targetBounds.width)
        XCTAssertGreaterThanOrEqual(customMapping.targetVideoRect.height, targetBounds.height)
    }

    func testCustomScaleUsesMPVVideoZoom() {
        XCTAssertEqual(
            MPVContentModeSnapshot.custom(scale: 2).nativeVideoZoom,
            1.0,
            accuracy: 0.001
        )
        XCTAssertEqual(MPVContentModeSnapshot.custom(scale: 0.5).nativeVideoZoom, -1.0, accuracy: 0.001)
        XCTAssertEqual(MPVContentModeSnapshot.fit.nativeVideoZoom, 0.0)
        XCTAssertEqual(MPVContentModeSnapshot.fill.nativeVideoZoom, 0.0)
    }
}
