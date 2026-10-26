import Foundation
import Testing
@testable import Nutola

struct JaroWinklerTests {
    @Test func testIdenticalStrings() {
        #expect(abs((JaroWinkler.similarity("nutola", "nutola")) - (1.0)) <= 0.0001)
    }

    @Test func testEmptyStrings() {
        #expect(abs((JaroWinkler.similarity("", "")) - (1.0)) <= 0.0001)
        #expect(abs((JaroWinkler.similarity("abc", "")) - (0.0)) <= 0.0001)
    }

    @Test func testCloseTypo() {
        // "nutola" vs "nutoa" — missing one letter. Should score high (>0.9).
        let score = JaroWinkler.similarity("nutola", "nutoa")
        #expect(score > 0.9)
    }

    @Test func testUnrelated() {
        let score = JaroWinkler.similarity("nutola", "banana")
        #expect(score < 0.6)
    }

    @Test func testCommonPrefixBonus() {
        // Strings sharing a 4-char prefix score higher than same-jaro pairs
        // with a shorter prefix.
        let withPrefix = JaroWinkler.similarity("martha", "marhta")
        #expect(withPrefix > 0.95)
    }
}
