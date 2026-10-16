import Foundation
import CGPhoto2

/// Internal widget-tree helpers. Not part of the public API.
///
/// libgphoto2's config is exposed as a tree of `CameraWidget*` nodes, and leaves carry
/// typed values. These helpers find a leaf by name, read/write it, and call
/// `gp_camera_set_single_config` (more efficient than `gp_camera_set_config` which
/// writes the entire tree on every change).
enum WidgetHelpers {
    /// The `gp_camera_get_config` behind `resolveLeaf`, and so behind the
    /// per-name reads and writes that use it: it rebuilds the whole tree each
    /// call, whichever leaf the caller wants. Caller owns the returned root.
    static func fetchRoot(
        camera: UnsafeMutablePointer<Camera>,
        context: OpaquePointer
    ) throws -> OpaquePointer? {
        var root: OpaquePointer? = nil
        try CameraError.check(gp_camera_get_config(camera, &root, context))
        return root
    }

    /// Resolve a leaf widget by name from the camera's config tree. Costs one
    /// full-tree `fetchRoot` per call.
    /// Caller owns the returned root and must `gp_widget_unref(root)` after use.
    /// The leaf is borrowed from the root, so do not unref it separately.
    static func resolveLeaf(
        camera: UnsafeMutablePointer<Camera>,
        context: OpaquePointer,
        name: String
    ) throws -> (root: OpaquePointer, leaf: OpaquePointer) {
        guard let root = try fetchRoot(camera: camera, context: context) else {
            throw CameraError.propertyNotFound(name: name)
        }

        var leaf: OpaquePointer? = nil
        let rc = name.withCString { cName in
            gp_widget_get_child_by_name(root, cName, &leaf)
        }
        if rc != GP_OK || leaf == nil {
            gp_widget_unref(root)
            throw CameraError.propertyNotFound(name: name)
        }
        return (root, leaf!)
    }

    static func widgetType(_ widget: OpaquePointer) -> CameraWidgetType {
        var t = CameraWidgetType(rawValue: 0)
        _ = gp_widget_get_type(widget, &t)
        return t
    }

    static func typeName(_ type: CameraWidgetType) -> String {
        switch type {
        case GP_WIDGET_WINDOW: return "WINDOW"
        case GP_WIDGET_SECTION: return "SECTION"
        case GP_WIDGET_TEXT: return "TEXT"
        case GP_WIDGET_RANGE: return "RANGE"
        case GP_WIDGET_TOGGLE: return "TOGGLE"
        case GP_WIDGET_RADIO: return "RADIO"
        case GP_WIDGET_MENU: return "MENU"
        case GP_WIDGET_BUTTON: return "BUTTON"
        case GP_WIDGET_DATE: return "DATE"
        default: return "UNKNOWN"
        }
    }

    /// Read a string-valued widget (TEXT, RADIO, MENU).
    static func readString(_ widget: OpaquePointer) throws -> String {
        let type = widgetType(widget)
        guard type == GP_WIDGET_TEXT || type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU else {
            throw CameraError.widgetTypeMismatch(expected: "TEXT/RADIO/MENU", got: typeName(type))
        }
        var cString: UnsafePointer<CChar>? = nil
        try withUnsafeMutablePointer(to: &cString) { ptr in
            try CameraError.check(gp_widget_get_value(widget, UnsafeMutableRawPointer(ptr)))
        }
        guard let cString else { return "" }
        return String(cString: cString)
    }

    /// Write a string-valued widget. Caller must follow with `commit` to push to camera.
    static func writeString(_ widget: OpaquePointer, value: String) throws {
        let type = widgetType(widget)
        guard type == GP_WIDGET_TEXT || type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU else {
            throw CameraError.widgetTypeMismatch(expected: "TEXT/RADIO/MENU", got: typeName(type))
        }
        try value.withCString { cValue in
            try CameraError.check(gp_widget_set_value(widget, UnsafeMutableRawPointer(mutating: cValue)))
        }
    }


    static func writeFloat(_ widget: OpaquePointer, value: Float) throws {
        let type = widgetType(widget)
        guard type == GP_WIDGET_RANGE else {
            throw CameraError.widgetTypeMismatch(expected: "RANGE", got: typeName(type))
        }
        var v = value
        try withUnsafeMutablePointer(to: &v) { ptr in
            try CameraError.check(gp_widget_set_value(widget, UnsafeMutableRawPointer(ptr)))
        }
    }

    /// Read a TOGGLE widget as Int32 (0/1/2).
    static func readToggle(_ widget: OpaquePointer) throws -> Int32 {
        let type = widgetType(widget)
        guard type == GP_WIDGET_TOGGLE else {
            throw CameraError.widgetTypeMismatch(expected: "TOGGLE", got: typeName(type))
        }
        var value: Int32 = 0
        try withUnsafeMutablePointer(to: &value) { ptr in
            try CameraError.check(gp_widget_get_value(widget, UnsafeMutableRawPointer(ptr)))
        }
        return value
    }

    static func writeToggle(_ widget: OpaquePointer, value: Int32) throws {
        let type = widgetType(widget)
        guard type == GP_WIDGET_TOGGLE else {
            throw CameraError.widgetTypeMismatch(expected: "TOGGLE", got: typeName(type))
        }
        var v = value
        try withUnsafeMutablePointer(to: &v) { ptr in
            try CameraError.check(gp_widget_set_value(widget, UnsafeMutableRawPointer(ptr)))
        }
    }

    /// Read a DATE widget, which libgphoto2 stores as Unix seconds in an Int32.
    static func readDate(_ widget: OpaquePointer) throws -> Int32 {
        let type = widgetType(widget)
        guard type == GP_WIDGET_DATE else {
            throw CameraError.widgetTypeMismatch(expected: "DATE", got: typeName(type))
        }
        var value: Int32 = 0
        try withUnsafeMutablePointer(to: &value) { ptr in
            try CameraError.check(gp_widget_get_value(widget, UnsafeMutableRawPointer(ptr)))
        }
        return value
    }

    /// Write a DATE widget as Unix seconds. Caller must follow with `commit` to push to camera.
    static func writeDate(_ widget: OpaquePointer, value: Int32) throws {
        let type = widgetType(widget)
        guard type == GP_WIDGET_DATE else {
            throw CameraError.widgetTypeMismatch(expected: "DATE", got: typeName(type))
        }
        var v = value
        try withUnsafeMutablePointer(to: &v) { ptr in
            try CameraError.check(gp_widget_set_value(widget, UnsafeMutableRawPointer(ptr)))
        }
    }


    static func choices(_ widget: OpaquePointer) throws -> [String] {
        let type = widgetType(widget)
        guard type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU else {
            throw CameraError.widgetTypeMismatch(expected: "RADIO/MENU", got: typeName(type))
        }
        let count = gp_widget_count_choices(widget)
        guard count > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            var c: UnsafePointer<CChar>? = nil
            if gp_widget_get_choice(widget, i, &c) == GP_OK, let c {
                out.append(String(cString: c))
            }
        }
        return out
    }

    /// Push a modified leaf back to the camera (single-config, faster than full-tree write).
    static func commit(
        camera: UnsafeMutablePointer<Camera>,
        context: OpaquePointer,
        name: String,
        leaf: OpaquePointer
    ) throws {
        try name.withCString { cName in
            try CameraError.check(gp_camera_set_single_config(camera, cName, leaf, context))
        }
    }
}
