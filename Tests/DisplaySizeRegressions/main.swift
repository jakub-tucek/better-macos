import Foundation
import CoreGraphics

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS: \(message)")
}

let size = CGSize(width: 597.6, height: 336.15)
let diagonal = DisplaySize.diagonalInches(for: size)!
expect(abs(diagonal - 27) < 0.01, "physical millimeters convert to a 27-inch diagonal")
expect(DisplaySize.diagonalInches(for: CGSize(width: size.height, height: size.width)) == diagonal,
       "rotation does not change physical diagonal")
for invalid in [CGSize.zero, CGSize(width: 0, height: 100), CGSize(width: 100, height: 0),
                CGSize(width: -1, height: 100), CGSize(width: CGFloat.infinity, height: 100),
                CGSize(width: 100, height: CGFloat.nan)] {
    expect(DisplaySize.diagonalInches(for: invalid) == nil, "unavailable or invalid dimensions have no size")
}
expect(DisplaySize.label(name: "Studio", diagonalInches: 27) ==
       "Studio · \(27.0.formatted(.number.precision(.fractionLength(1))))″",
       "display label includes localized diagonal with inch units")
for missing in [nil, Double.nan, Double.infinity, 0, -1] as [Double?] {
    expect(DisplaySize.label(name: "Studio", diagonalInches: missing) == "Studio",
           "unknown size preserves the original display name")
}
