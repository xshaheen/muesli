import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Custom instructions editor rules")
struct CustomInstructionsEditorTests {

    @Test("truncation keeps leading whitespace and drops only trailing overflow")
    func truncationKeepsLeadingWhitespace() {
        let leading = String(repeating: " ", count: 100)
        let draft = leading + String(repeating: "a", count: 2_050)

        let result = CustomInstructionsEditorRules.truncated(draft)

        #expect(result.hasPrefix(leading))
        #expect(result.count == 100 + CustomInstructions.maxLength)
        #expect(CustomInstructions.normalized(result).count == CustomInstructions.maxLength)
    }

    @Test("a draft ending in whitespace under the cap is left as typed")
    func whitespaceUnderCapIsUntouched() {
        #expect(CustomInstructionsEditorRules.truncated("Use British English ") == "Use British English ")
        #expect(CustomInstructionsEditorRules.truncated("First line\n\n") == "First line\n\n")
        #expect(CustomInstructionsEditorRules.truncated("") == "")
    }

    @Test("commit decisions compare normalized values")
    func commitComparesNormalized() {
        #expect(CustomInstructionsEditorRules.shouldCommit(draft: " Be concise. \n", committed: "Be concise.") == false)
        #expect(CustomInstructionsEditorRules.shouldCommit(draft: "Be concise!", committed: "Be concise.") == true)
        #expect(CustomInstructionsEditorRules.shouldCommit(draft: "   ", committed: "") == false)
        #expect(CustomInstructionsEditorRules.shouldCommit(draft: "", committed: "Old") == true)
    }

    @Test("the counter reports the trimmed length")
    func counterReportsTrimmedLength() {
        #expect(CustomInstructionsEditorRules.count("  abc  \n") == 3)
        #expect(CustomInstructionsEditorRules.count("") == 0)
    }
}
