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

    func testCustomScaleUsesFitBaseMatchingFitMode() {
        let targetBounds = CGRect(x: 0, y: 0, width: 852, height: 393)
        let fitMapping = MPVDisplayGeometry.make(
            canvasSize: targetBounds.size,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: targetBounds,
            contentMode: .fit
        )
        let customMapping = MPVDisplayGeometry.make(
            canvasSize: targetBounds.size,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: targetBounds,
            contentMode: .custom(scale: 1.0)
        )
        let zoomedCustomMapping = MPVDisplayGeometry.make(
            canvasSize: targetBounds.size,
            videoAspectRatio: 16.0 / 9.0,
            targetBounds: targetBounds,
            contentMode: .custom(scale: 1.5)
        )

        // Custom shares Fit's contain mapping so 100% custom equals Fit.
        XCTAssertEqual(customMapping.targetVideoRect, fitMapping.targetVideoRect)
        XCTAssertEqual(customMapping.scale, fitMapping.scale, accuracy: 0.001)
        // Zoom lives in libmpv `video-zoom`; geometry stays on the Fit base.
        XCTAssertEqual(zoomedCustomMapping.targetVideoRect, fitMapping.targetVideoRect)
        XCTAssertLessThan(customMapping.targetVideoRect.width, targetBounds.width)
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
