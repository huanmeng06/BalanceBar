import AppKit
import XCTest
@testable import BalanceBar

final class DashboardScrollClampingTests: XCTestCase {
    func testClipViewRejectsRepeatedTopAndBottomScrollProposals() {
        let documentView = FlippedDashboardDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let clipView = DashboardClipView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        clipView.documentView = documentView
        clipView.layoutSubtreeIfNeeded()

        let geometry = makeGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let topProposal = clipView.bounds.minY - 80
        let bottomProposal = clipView.bounds.minY + geometry.maximumOffset + 80

        for proposedY in [topProposal, bottomProposal, topProposal, bottomProposal] {
            clipView.scroll(
                to: NSPoint(x: clipView.bounds.minX, y: proposedY)
            )
            let visibleDocumentRect = clipView.convert(
                clipView.bounds,
                to: documentView
            )
            let visualOffset = geometry.visualOffset(for: visibleDocumentRect)
            XCTAssertEqual(
                visualOffset,
                geometry.clampedVisualOffset(visualOffset),
                accuracy: 0.0001
            )
        }

        let bottomVisibleRect = clipView.convert(clipView.bounds, to: documentView)
        XCTAssertEqual(geometry.visualOffset(for: bottomVisibleRect), geometry.maximumOffset)
    }

    func testStableRigidEdgesDoNotRewriteBoundsForRepeatedOverscrollProposals() {
        let documentView = FlippedDashboardDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let clipView = DashboardClipView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        clipView.documentView = documentView
        clipView.postsBoundsChangedNotifications = true
        clipView.layoutSubtreeIfNeeded()

        var boundsChangeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { _ in
            boundsChangeCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let geometry = makeGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let bottomProposal = clipView.bounds.minY + geometry.maximumOffset + 80
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.minX, y: bottomProposal)
        )
        let countAfterInitialClamp = boundsChangeCount

        for _ in 0..<20 {
            clipView.scroll(
                to: NSPoint(x: clipView.bounds.minX, y: bottomProposal)
            )
        }

        XCTAssertEqual(boundsChangeCount, countAfterInitialClamp)

        clipView.scroll(
            to: NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY - 5)
        )
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.minX, y: bottomProposal)
        )
        let visibleDocumentRect = clipView.convert(
            clipView.bounds,
            to: documentView
        )
        XCTAssertEqual(
            geometry.visualOffset(for: visibleDocumentRect),
            geometry.maximumOffset,
            accuracy: 0.0001
        )
    }

    func testClipViewClampsUnflippedDocumentScrollProposals() {
        let documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let clipView = DashboardClipView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        clipView.documentView = documentView
        clipView.layoutSubtreeIfNeeded()

        let geometry = makeGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )

        for proposedY in [
            clipView.bounds.minY - 80,
            clipView.bounds.minY + geometry.maximumOffset + 80
        ] {
            clipView.scroll(
                to: NSPoint(x: clipView.bounds.minX, y: proposedY)
            )
            let visibleDocumentRect = clipView.convert(
                clipView.bounds,
                to: documentView
            )
            let visualOffset = geometry.visualOffset(for: visibleDocumentRect)
            XCTAssertEqual(
                visualOffset,
                geometry.clampedVisualOffset(visualOffset),
                accuracy: 0.0001
            )
        }
    }

    func testClipViewClampsDirectBoundsOriginWritesWithoutChangingLegalScroll() {
        let documentView = FlippedDashboardDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let clipView = DashboardClipView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        clipView.documentView = documentView
        clipView.layoutSubtreeIfNeeded()

        let geometry = makeGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let legalOffset = geometry.maximumOffset / 2
        let legalBounds = clipView.bounds
        let legalOriginY = legalBounds.minY + legalOffset

        clipView.setBoundsOrigin(
            NSPoint(x: legalBounds.minX, y: legalOriginY)
        )
        let legalVisibleRect = clipView.convert(clipView.bounds, to: documentView)
        XCTAssertEqual(
            geometry.visualOffset(for: legalVisibleRect),
            legalOffset,
            accuracy: 0.0001
        )

        clipView.setBoundsOrigin(
            NSPoint(x: legalBounds.minX, y: legalOriginY + 500)
        )
        let bottomVisibleRect = clipView.convert(clipView.bounds, to: documentView)
        XCTAssertEqual(
            geometry.visualOffset(for: bottomVisibleRect),
            geometry.maximumOffset,
            accuracy: 0.0001
        )
    }

    func testRapidAlternatingFractionalEdgeProposalsSettleToOneRigidEdge() {
        let documentView = FlippedDashboardDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let clipView = DashboardClipView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        clipView.documentView = documentView
        clipView.layoutSubtreeIfNeeded()

        let geometry = makeGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let topProposals: [CGFloat] = [
            0.2, -0.2, 0.35, -0.35, 0.49, -0.49
        ]
        for proposedY in topProposals {
            clipView.scroll(
                to: NSPoint(x: clipView.bounds.minX, y: proposedY)
            )
            let visibleRect = clipView.convert(clipView.bounds, to: documentView)
            XCTAssertEqual(
                geometry.visualOffset(for: visibleRect),
                0,
                accuracy: 0.0001
            )
        }

        let bottomProposals: [CGFloat] = [
            geometry.maximumOffset - 0.2,
            geometry.maximumOffset + 0.2,
            geometry.maximumOffset - 0.35,
            geometry.maximumOffset + 0.35,
            geometry.maximumOffset - 0.49,
            geometry.maximumOffset + 0.49
        ]
        for proposedY in bottomProposals {
            clipView.setBoundsOrigin(
                NSPoint(x: clipView.bounds.minX, y: proposedY)
            )
            let visibleRect = clipView.convert(clipView.bounds, to: documentView)
            XCTAssertEqual(
                geometry.visualOffset(for: visibleRect),
                geometry.maximumOffset,
                accuracy: 0.0001
            )
        }
    }

    func testInRangeNonEdgeOriginIsPreservedForScrollAndDirectBoundsWrites() {
        let documentView = FlippedDashboardDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let clipView = DashboardClipView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        clipView.documentView = documentView
        clipView.layoutSubtreeIfNeeded()

        let geometry = makeGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let legalOffset = 73.25
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.minX, y: legalOffset)
        )
        XCTAssertEqual(clipView.bounds.origin.y, legalOffset, accuracy: 0.0001)

        let directOffset = geometry.maximumOffset - 73.25
        clipView.setBoundsOrigin(
            NSPoint(x: clipView.bounds.minX, y: directOffset)
        )
        XCTAssertEqual(clipView.bounds.origin.y, directOffset, accuracy: 0.0001)
    }

    func testShortDocumentHasNoVerticalOffset() {
        let geometry = makeGeometry(
            documentBounds: NSRect(x: 12, y: 40, width: 400, height: 180),
            viewportHeight: 240,
            isDocumentFlipped: true
        )

        XCTAssertEqual(geometry.maximumOffset, 0)
        XCTAssertEqual(geometry.clampedVisualOffset(-80), 0)
        XCTAssertEqual(geometry.clampedVisualOffset(80), 0)
        XCTAssertEqual(
            geometry.visibleDocumentRect(forVisualOffset: 80).minY,
            40
        )
    }

    func testFlippedDocumentClampsTopAndBottomOverscroll() {
        let geometry = makeGeometry(
            documentBounds: NSRect(x: 0, y: 25, width: 400, height: 300),
            viewportHeight: 100,
            isDocumentFlipped: true
        )

        XCTAssertEqual(
            geometry.clampedVisualOffset(
                for: NSRect(x: 0, y: 5, width: 400, height: 100)
            ),
            0
        )
        XCTAssertEqual(
            geometry.clampedVisualOffset(
                for: NSRect(x: 0, y: 260, width: 400, height: 100)
            ),
            200
        )
        XCTAssertEqual(
            geometry.visibleDocumentRect(forVisualOffset: 200).minY,
            225
        )
    }

    func testUnflippedDocumentUsesVisualTopForBothBounds() {
        let geometry = makeGeometry(
            documentBounds: NSRect(x: 0, y: 25, width: 400, height: 300),
            viewportHeight: 100,
            isDocumentFlipped: false
        )

        let visualTop = NSRect(x: 0, y: 225, width: 400, height: 100)
        let visualBottom = NSRect(x: 0, y: 25, width: 400, height: 100)
        let topOverscroll = NSRect(x: 0, y: 245, width: 400, height: 100)
        let bottomOverscroll = NSRect(x: 0, y: 5, width: 400, height: 100)

        XCTAssertEqual(geometry.clampedVisualOffset(for: visualTop), 0)
        XCTAssertEqual(geometry.clampedVisualOffset(for: visualBottom), 200)
        XCTAssertEqual(geometry.clampedVisualOffset(for: topOverscroll), 0)
        XCTAssertEqual(geometry.clampedVisualOffset(for: bottomOverscroll), 200)
        XCTAssertEqual(
            geometry.visibleDocumentRect(forVisualOffset: 0).minY,
            225
        )
        XCTAssertEqual(
            geometry.visibleDocumentRect(forVisualOffset: 200).minY,
            25
        )
    }

    func testWindowHeightChangeReclampsExistingOffset() {
        let tallViewport = makeGeometry(
            documentBounds: NSRect(x: 0, y: 0, width: 400, height: 500),
            viewportHeight: 300,
            isDocumentFlipped: false
        )
        let resizedViewport = makeGeometry(
            documentBounds: tallViewport.documentBounds,
            viewportHeight: 460,
            isDocumentFlipped: false
        )

        XCTAssertEqual(tallViewport.maximumOffset, 200)
        XCTAssertEqual(resizedViewport.maximumOffset, 40)
        XCTAssertEqual(resizedViewport.clampedVisualOffset(150), 40)
    }

    func testDocumentHeightChangeRemovesStaleBottomOffset() {
        let longDocument = makeGeometry(
            documentBounds: NSRect(x: 0, y: 10, width: 400, height: 440),
            viewportHeight: 200,
            isDocumentFlipped: true
        )
        let shortenedDocument = makeGeometry(
            documentBounds: NSRect(x: 0, y: 10, width: 400, height: 170),
            viewportHeight: 200,
            isDocumentFlipped: true
        )

        XCTAssertEqual(longDocument.maximumOffset, 240)
        XCTAssertEqual(shortenedDocument.maximumOffset, 0)
        XCTAssertEqual(shortenedDocument.clampedVisualOffset(240), 0)
    }

    func testVisibleDocumentRectRoundTripsForBothCoordinateSystems() {
        for isFlipped in [false, true] {
            let geometry = makeGeometry(
                documentBounds: NSRect(x: 4, y: 30, width: 400, height: 260),
                viewportHeight: 80,
                isDocumentFlipped: isFlipped
            )
            let offset: CGFloat = 55
            let visibleRect = geometry.visibleDocumentRect(forVisualOffset: offset)

            XCTAssertEqual(
                geometry.visualOffset(for: visibleRect),
                offset,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                geometry.clampedVisualOffset(for: visibleRect),
                offset,
                accuracy: 0.0001
            )
        }
    }

    func testContentOriginEdgeMatchesDocumentAndClipCoordinateSystems() {
        let unflippedDocument = makeGeometry(
            documentBounds: NSRect(x: 0, y: 10, width: 400, height: 260),
            viewportHeight: 80,
            isDocumentFlipped: false
        ).visibleDocumentRect(forVisualOffset: 55)
        let flippedDocument = makeGeometry(
            documentBounds: NSRect(x: 0, y: 10, width: 400, height: 260),
            viewportHeight: 80,
            isDocumentFlipped: true
        ).visibleDocumentRect(forVisualOffset: 55)

        let unflippedGeometry = makeGeometry(
            documentBounds: NSRect(x: 0, y: 10, width: 400, height: 260),
            viewportHeight: 80,
            isDocumentFlipped: false
        )
        let flippedGeometry = makeGeometry(
            documentBounds: NSRect(x: 0, y: 10, width: 400, height: 260),
            viewportHeight: 80,
            isDocumentFlipped: true
        )

        XCTAssertEqual(
            unflippedGeometry.contentOriginDocumentY(
                for: unflippedDocument,
                contentViewIsFlipped: false
            ),
            unflippedDocument.minY
        )
        XCTAssertEqual(
            unflippedGeometry.contentOriginDocumentY(
                for: unflippedDocument,
                contentViewIsFlipped: true
            ),
            unflippedDocument.maxY
        )
        XCTAssertEqual(
            flippedGeometry.contentOriginDocumentY(
                for: flippedDocument,
                contentViewIsFlipped: false
            ),
            flippedDocument.maxY
        )
        XCTAssertEqual(
            flippedGeometry.contentOriginDocumentY(
                for: flippedDocument,
                contentViewIsFlipped: true
            ),
            flippedDocument.minY
        )
    }

    private func makeGeometry(
        documentBounds: NSRect,
        viewportHeight: CGFloat,
        isDocumentFlipped: Bool
    ) -> DashboardScrollGeometry {
        DashboardScrollGeometry(
            documentBounds: documentBounds,
            viewportHeight: viewportHeight,
            isDocumentFlipped: isDocumentFlipped
        )
    }
}

private final class FlippedDashboardDocumentView: NSView {
    override var isFlipped: Bool { true }
}
