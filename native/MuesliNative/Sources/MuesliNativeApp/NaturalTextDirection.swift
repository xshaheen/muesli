import AppKit
import Foundation
import SwiftUI

/// The presentation direction of a text block, resolved by Unicode's
/// first-strong bidirectional rule without changing the source text.
enum NaturalTextDirection: Sendable {
    case leftToRight
    case rightToLeft

    private static let leftToRightMatcher = try! NSRegularExpression(
        pattern: #"\p{Bidi_Class=Left_To_Right}"#
    )
    private static let rightToLeftMatcher = try! NSRegularExpression(
        pattern: #"[\p{Bidi_Class=Right_To_Left}\p{Bidi_Class=Arabic_Letter}]"#
    )

    static func resolve(_ text: String) -> Self {
        let range = NSRange(text.startIndex..., in: text)
        let leftToRightLocation = leftToRightMatcher
            .firstMatch(in: text, range: range)?
            .range.location ?? NSNotFound

        if leftToRightLocation == 0 {
            return .leftToRight
        }

        let rightToLeftLocation = rightToLeftMatcher
            .firstMatch(in: text, range: range)?
            .range.location ?? NSNotFound

        if rightToLeftLocation < leftToRightLocation {
            return .rightToLeft
        }

        // Stable fallback for empty text and content containing only weak or
        // neutral characters such as digits, punctuation, and emoji.
        return .leftToRight
    }

    var layoutDirection: LayoutDirection {
        switch self {
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leftToRight: .leading
        case .rightToLeft: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leftToRight: .leading
        case .rightToLeft: .trailing
        }
    }

    var writingDirection: NSWritingDirection {
        switch self {
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var appKitTextAlignment: NSTextAlignment {
        switch self {
        case .leftToRight: .left
        case .rightToLeft: .right
        }
    }
}
