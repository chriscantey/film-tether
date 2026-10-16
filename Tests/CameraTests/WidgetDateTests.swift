import XCTest
import CGPhoto2
@testable import Camera

/// The DATE read and write behind the camera clock. The widgets are built in
/// memory with libgphoto2's widget API, so nothing touches a camera.
final class WidgetDateTests: XCTestCase {

    private func widget(_ type: CameraWidgetType, _ name: String) -> OpaquePointer {
        var w: OpaquePointer? = nil
        XCTAssertEqual(gp_widget_new(type, name, &w), GP_OK)
        return w!
    }

    func testDateLeafWritesAndReadsBack() throws {
        let leaf = widget(GP_WIDGET_DATE, "datetimeutc")
        defer { gp_widget_unref(leaf) }
        try WidgetHelpers.writeDate(leaf, value: 1_790_000_000)
        XCTAssertEqual(try WidgetHelpers.readDate(leaf), 1_790_000_000)
    }

    func testTextLeafIsRefusedBothWays() {
        let leaf = widget(GP_WIDGET_TEXT, "datetimeutc")
        defer { gp_widget_unref(leaf) }
        XCTAssertThrowsError(try WidgetHelpers.writeDate(leaf, value: 1_790_000_000)) { error in
            guard case CameraError.widgetTypeMismatch(let expected, let got) = error else {
                return XCTFail("expected widgetTypeMismatch, got \(error)")
            }
            XCTAssertEqual(expected, "DATE")
            XCTAssertEqual(got, "TEXT")
        }
        XCTAssertThrowsError(try WidgetHelpers.readDate(leaf)) { error in
            guard case CameraError.widgetTypeMismatch = error else {
                return XCTFail("expected widgetTypeMismatch, got \(error)")
            }
        }
    }

    /// A refused write leaves the leaf's value as it was.
    func testRefusedWriteChangesNothing() throws {
        let leaf = widget(GP_WIDGET_TEXT, "datetimeutc")
        defer { gp_widget_unref(leaf) }
        try WidgetHelpers.writeString(leaf, value: "unchanged")
        XCTAssertThrowsError(try WidgetHelpers.writeDate(leaf, value: 42))
        XCTAssertEqual(try WidgetHelpers.readString(leaf), "unchanged")
    }
}
