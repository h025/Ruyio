import Testing
@testable import RuyioUI

struct JSONFormattingTests {
    @Test func indentsWithoutReorderingKeysOrRespellingNumbers() {
        let text = #"{"z":1.50,"a":[true,null,{}],"s":"x {y}: [z], \"q\"","e":[]}"#
        #expect(JSONFormatting.indented(text) == """
        {
          "z": 1.50,
          "a": [
            true,
            null,
            {}
          ],
          "s": "x {y}: [z], \\"q\\"",
          "e": []
        }
        """)
    }

    @Test func textCutShortStillFormats() {
        #expect(JSONFormatting.indented(#"{"a": [1, 2"#) == "{\n  \"a\": [\n    1,\n    2")
    }

    @Test func keysAreTellApartFromStringValues() {
        let tokens = JSONFormatting.tokens(JSONFormatting.indented(#"{"k": "v", "n": -2e3, "b": false}"#))
        func kind(_ text: String) -> JSONFormatting.Token? { tokens.first { $0.0 == text }?.1 }
        #expect(kind("\"k\"") == .key)
        #expect(kind("\"v\"") == .string)
        #expect(kind("-2e3") == .number)
        #expect(kind("false") == .literal)
        #expect(kind("{") == .punctuation)
    }
}
