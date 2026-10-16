import Foundation

/// How a free-form camera or film name becomes the maker fields of `CaptureInfo`.
///
/// Every writer of these fields has to use the same lists and the same split, or the same
/// name typed into two apps exports differently.
public enum CaptureNames {
    /// Manufacturers matched against the leading token of a camera string. Used only to
    /// decide where to split "Leica M6" into Make Leica, Model "Leica M6". A brand
    /// dictionary for the split, not a list of cameras.
    public static let knownCameraMakers: [String] = [
        "Leica", "Nikon", "Canon", "Hasselblad", "Contax", "Pentax", "Mamiya",
        "Rollei", "Rolleiflex", "Minolta", "Olympus", "Fuji", "Fujifilm",
        "Yashica", "Voigtländer", "Voigtlander", "Konica", "Bronica", "Zeiss",
        "Polaroid", "Ricoh", "Sigma", "Sony", "Plaubel", "Linhof", "Graflex",
        "Zenza", "Zorki", "Kiev", "Bessa", "Chamonix", "Intrepid", "Horseman",
    ]

    public static let knownFilmMakers: [String] = [
        "Kodak", "Fuji", "Fujifilm", "Ilford", "Cinestill", "Lomography",
        "Lomo", "Agfa", "Rollei", "Foma", "Fomapan", "Kentmere", "Adox",
        "Bergger", "Ferrania", "Polaroid", "Harman", "Washi", "Kosmo",
    ]

    /// Splits a camera string into EXIF Make and Model. A first word on the list, with more
    /// after it, becomes Make. Model is always the full string ("Olympus Infinity Zoom
    /// 230"), the way Canon and Nikon write it and the form both apps agree on. Any other
    /// first word gives no Make at all.
    public static func makeAndModel(camera: String) -> (make: String?, model: String) {
        guard !camera.isEmpty else { return (nil, "") }
        guard let sp = camera.firstIndex(of: " ") else { return (nil, camera) }
        let firstWord = String(camera[..<sp])
        let rest = camera[camera.index(after: sp)...].trimmingCharacters(in: .whitespaces)
        let known = knownCameraMakers.contains { $0.caseInsensitiveCompare(firstWord) == .orderedSame }
        return (!rest.isEmpty && known) ? (firstWord, camera) : (nil, camera)
    }

    /// The film's manufacturer when its leading token is on the list, nil otherwise.
    public static func filmMaker(film: String) -> String? {
        let token = film.firstIndex(of: " ").map { String(film[..<$0]) } ?? film
        let known = knownFilmMakers.contains { $0.caseInsensitiveCompare(token) == .orderedSame }
        return known ? token : nil
    }
}

extension CaptureInfo {
    /// Sets the camera and derives its make with `CaptureNames.makeAndModel`. Leading and
    /// trailing space is dropped, and an empty name clears both fields.
    public mutating func setCamera(_ name: String?) {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let split = CaptureNames.makeAndModel(camera: trimmed)
        camera = split.model.isEmpty ? nil : split.model
        cameraMake = split.make
    }

    /// Sets the film and derives its maker with `CaptureNames.filmMaker`. An empty name
    /// clears both fields.
    public mutating func setFilm(_ name: String?) {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        film = trimmed.isEmpty ? nil : trimmed
        filmMaker = trimmed.isEmpty ? nil : CaptureNames.filmMaker(film: trimmed)
    }
}
