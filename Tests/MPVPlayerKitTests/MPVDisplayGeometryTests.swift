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

    func testAspectFillUsesUniformScaleAndCanvasAsSource() {
        let mapping = MPVDisplayGeometry.make(
            canvasSize: CGSize(width: 852, height: 393),
            videoAspectRatio: 2.35,
            targetBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
            contentMode: .fill
        )

        XCTAssertEqual(mapping.rotation, 0.0)
        XCTAssertEqual(mapping.sourceVideoRect.size, CGSize(width: 852, height: 393))
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
        XCTAssertGreaterThanOrEqual(mapping.targetVideoRect.width, 393.0)
        XCTAssertGreaterThanOrEqual(mapping.targetVideoRect.height, 852.0)
    }
}
