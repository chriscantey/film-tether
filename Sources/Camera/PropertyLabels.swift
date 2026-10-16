import Foundation

/// Display labels for libgphoto2 widget values exposed by the Canon EOS 7D's PTP
/// driver. The driver returns terse strings, `"160"` for ISO, `"2.8"` for aperture,
/// `"AV"` for the mode dial, and this file maps them to the strings a photographer
/// recognizes.
///
/// All methods are pure and synchronous, so call them from any actor. Each label
/// function passes an unknown value through, trimmed of spaces.
/// `transform(choices:)` drops a choice whose label repeats an earlier one.
///
/// A lone em-dash (U+2014) is the app's placeholder for a value the body has
/// not reported. The app compares against that exact string (AppModel,
/// StatusFooter), so the functions here pass it through and it stays an
/// em-dash.
public enum PropertyLabels {

    // MARK: - ISO

    /// `"160"` → `"ISO 160"`. Numeric values get the prefix, `"Auto"` stays `"Auto"`.
    public static func iso(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        if Int(trimmed) != nil {
            return "ISO \(trimmed)"
        }
        return trimmed
    }

    // MARK: - Aperture

    /// `"2.8"` → `"f/2.8"`. Already-prefixed values pass through.
    public static func aperture(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        if trimmed.lowercased().hasPrefix("f/") || trimmed.lowercased().hasPrefix("f ") {
            return trimmed
        }
        if Double(trimmed) != nil {
            return "f/\(trimmed)"
        }
        return trimmed
    }

    // MARK: - Shutter

    /// Shutter speed as libgphoto2's Canon driver reports it. On the 7D that is a
    /// fraction from 1/4 s up (`"1/200"`), which passes through, and whole or decimal
    /// seconds below that (`"30"`, `"2.5"`, `"0.8"`). Plus special strings: `"auto"`,
    /// `"bulb"`, `"Bulb"`.
    ///
    /// Decimal seconds show as seconds: `"2.5s"`, `"30s"`, and under one second
    /// `"0.8s"`, with trailing zeros dropped. The driver lists 0.8, 0.7, 0.6, 0.5,
    /// 0.4 and 0.3 between 1 s and 1/4, and each keeps its own label so every one
    /// of them stays in the menu.
    public static func shutter(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        let lower = trimmed.lowercased()
        if lower == "auto" { return "Auto" }
        if lower == "bulb" { return "Bulb" }
        if trimmed.contains("/") { return trimmed }
        if let s = Double(trimmed) {
            if s >= 1.0 {
                if s == s.rounded() {
                    return "\(Int(s))s"
                }
                return String(format: "%.1fs", s)
            }
            var text = String(format: "%.2f", s)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return "\(text)s"
        }
        return trimmed
    }

    // MARK: - White balance

    /// Canon WB mode names. libgphoto2 may report `"Auto"`, `"Daylight"`,
    /// `"Cloudy"`, `"Tungsten"`, `"Fluorescent"`, `"Flash"`, `"Custom"`,
    /// `"Color Temperature"` (the Kelvin-picker mode). They are already
    /// photographer-readable and pass through, trimmed of spaces, with one
    /// exception.
    ///
    /// `"Color Temperature"` is shown as "Temperature", which ties
    /// "Fluorescent" for longest at 88.4pt, the width ExposureBar's WB Mode
    /// slot is sized from. The Kelvin value itself lives in the Temperature
    /// stepper beside the picker.
    public static func whiteBalance(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        // Tolerant of Canon/libgphoto2 spelling drift: colour, no space,
        // "Temp" abbreviated. Anything that is the color-temperature mode
        // and nothing else.
        let squashed = trimmed.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "colour", with: "color")
        if squashed == "colortemperature" || squashed == "colortemp" { return "Temperature" }
        return trimmed
    }

    /// `5600` → `"5600K"`. nil, zero or a negative value shows the placeholder
    /// dash.
    public static func kelvin(_ raw: Int?) -> String {
        guard let k = raw, k > 0 else { return "—" }
        return "\(k)K"
    }

    // MARK: - Exposure mode (mode dial)

    /// Canon's mode-dial labels. libgphoto2 reports terse codes like `"M"`,
    /// `"Av"`, `"Tv"`, `"P"`, `"B"`, `"AV"`, `"TV"`, `"C1"`, `"C2"`, `"C3"`,
    /// `"A-DEP"`, `"Auto"`. Map to spelled-out names for the status bar.
    public static func exposureMode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        switch trimmed.uppercased() {
        case "M":     return "Manual (M)"
        case "AV", "AV MODE", "APERTURE PRIORITY", "APERTURE-PRIORITY":
            return "Aperture priority (Av)"
        case "TV", "TV MODE", "SHUTTER PRIORITY", "SHUTTER-PRIORITY":
            return "Shutter priority (Tv)"
        case "P":     return "Program (P)"
        case "B", "BULB":
            return "Bulb (B)"
        case "AUTO":  return "Auto"
        case "A-DEP": return "Auto-DEP"
        case "C1":    return "Custom 1 (C1)"
        case "C2":    return "Custom 2 (C2)"
        case "C3":    return "Custom 3 (C3)"
        default:      return trimmed
        }
    }

    // MARK: - Image format

    /// Canon image-format values from libgphoto2's choices on the 7D include strings
    /// like `"RAW"`, `"RAW + Large Fine JPEG"`, `"Large Fine JPEG"`, `"Small Normal JPEG"`.
    /// They pass through, since they're already readable.
    public static func imageFormat(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        return trimmed
    }

    // MARK: - Battery level

    /// Some libgphoto2 builds report battery as percentage (`"75%"`), others as integer
    /// (`"75"`). A bare integer gets `%`.
    public static func battery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        if trimmed.hasSuffix("%") { return trimmed }
        if Int(trimmed) != nil { return "\(trimmed)%" }
        return trimmed
    }

    // MARK: - Choices

    /// Apply the per-property label transform across a choice list, so the
    /// displayed options match the displayed current value.
    public static func transform(choices: [String], forProperty prop: String) -> [(raw: String, label: String)] {
        let formatter: (String) -> String
        switch prop {
        case "iso":           formatter = iso
        case "aperture":      formatter = aperture
        case "shutterspeed":  formatter = shutter
        case "whitebalance":  formatter = whiteBalance
        case "autoexposuremode", "expprogram": formatter = exposureMode
        case "imageformat":   formatter = imageFormat
        case "batterylevel":  formatter = battery
        default:              formatter = { $0 }
        }
        // Bodies occasionally repeat entries, and two distinct raw values can
        // format to the same display label. Either way the menu would show
        // duplicates the user can't distinguish, so keep the first occurrence
        // and preserve order.
        var seenRaw = Set<String>()
        var seenLabel = Set<String>()
        return choices.compactMap { raw in
            guard seenRaw.insert(raw).inserted else { return nil }
            let label = formatter(raw)
            guard seenLabel.insert(label).inserted else { return nil }
            return (raw: raw, label: label)
        }
    }
}
