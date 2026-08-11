import Foundation
import SwiftUI

/// The presentation direction of a text block, resolved by Unicode's
/// first-strong bidirectional rule without changing the source text.
enum NaturalTextDirection: Sendable {
    case leftToRight
    case rightToLeft

    private static let firstStrongMatcher = try! NSRegularExpression(
        pattern: #"(\p{Bidi_Class=Left_To_Right})|([\p{Bidi_Class=Right_To_Left}\p{Bidi_Class=Arabic_Letter}])"#
    )

    static func resolve(_ text: String) -> Self {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = firstStrongMatcher.firstMatch(in: text, range: range) else {
            // Stable fallback for empty text and content containing only weak
            // or neutral characters such as digits, punctuation, and emoji.
            return .leftToRight
        }
        return match.range(at: 1).location == NSNotFound ? .rightToLeft : .leftToRight
    }

    var layoutDirection: LayoutDirection {
        switch self {
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leftToRight: .leading
        case .rightToLeft: .trailing
        }
    }

}
