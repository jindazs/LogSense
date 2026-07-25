import Foundation
import ImageIO

struct ImageMetadata: Equatable {
    let date: String?
    let cameraModel: String?
    let lensModel: String?
}

enum ImageMetadataReader {
    static func read(from data: Data) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return ImageMetadata(date: nil, cameraModel: nil, lensModel: nil)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString =
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String ??
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String ??
            tiff?[kCGImagePropertyTIFFDateTime] as? String

        return ImageMetadata(
            date: normalizedDate(dateString),
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String
        )
    }

    static func normalizedDate(_ value: String?) -> String? {
        guard let value else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false

        guard let date = formatter.date(from: value) else { return nil }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
