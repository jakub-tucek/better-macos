import Foundation
import CoreGraphics

enum DisplaySize {
    /// Core Graphics reports physical dimensions in millimeters, not pixels.
    static func diagonalInches(for size: CGSize) -> Double? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let diagonal = hypot(Double(size.width), Double(size.height)) / 25.4
        return diagonal.isFinite ? diagonal : nil
    }

    static func label(name: String, diagonalInches: Double?) -> String {
        guard let diagonalInches, diagonalInches.isFinite, diagonalInches > 0 else { return name }
        let size = diagonalInches.formatted(.number.precision(.fractionLength(1)))
        return "\(name) · \(size)″"
    }
}
