import Foundation
import Testing
@testable import Nutola

struct ActionItemParserTests {
    @Test func testParsesUncheckedCheckbox() {
        let markdown = """
        ## Action Items
        - [ ] Send the proposal — Alice
        - [ ] Review the code
        """
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 2)
        #expect(!(items[0].isChecked))
        #expect(items[0].text == "Send the proposal")
        #expect(items[0].owner == "Alice")
        #expect(items[1].owner == nil)
        #expect(items[1].text == "Review the code")
    }

    @Test func testParsesCheckedCheckbox() {
        let markdown = "- [x] Done task\n- [X] Also done"
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 2)
        #expect(items[0].isChecked)
        #expect(items[1].isChecked)
    }

    @Test func testIgnoresNonCheckboxLines() {
        let markdown = """
        # Meeting Notes
        Some regular text.
        - Not a checkbox, just a bullet.
        - [ ] Real action item
        More text.
        """
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].text == "Real action item")
    }

    @Test func testOwnerExtractionWithParen() {
        let markdown = "- [ ] Fix the bug (Bob)"
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].text == "Fix the bug")
        #expect(items[0].owner == "Bob")
    }

    @Test func testOwnerExtractionWithHyphen() {
        let markdown = "- [ ] Deploy the service - Carol"
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].text == "Deploy the service")
        #expect(items[0].owner == "Carol")
    }

    @Test func testNoOwner() {
        let markdown = "- [ ] Just a task with no owner"
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].owner == nil)
        #expect(items[0].text == "Just a task with no owner")
    }

    @Test func testOpenItemsFiltersChecked() {
        let markdown = """
        - [x] Completed task
        - [ ] Open task
        - [X] Also completed
        - [ ] Another open task
        """
        let open = ActionItemParser.openItems(markdown)
        #expect(open.count == 2)
        #expect(open[0].text == "Open task")
        #expect(open[1].text == "Another open task")
    }

    @Test func testOpenCount() {
        let markdown = """
        - [x] Done
        - [ ] Todo 1
        - [ ] Todo 2
        """
        #expect(ActionItemParser.openCount(markdown) == 2)
    }

    @Test func testEmptyMarkdown() {
        #expect(ActionItemParser.parse("").isEmpty)
        #expect(ActionItemParser.openCount("") == 0)
    }

    @Test func testAsteriskBulletCheckbox() {
        let markdown = "* [ ] Task with asterisk"
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].text == "Task with asterisk")
    }

    @Test func testIndentedCheckbox() {
        let markdown = "  - [ ] Indented task"
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].text == "Indented task")
    }

    @Test func testLineNumberTracking() {
        let markdown = """
        Line 0
        Line 1
        - [ ] Task on line 2
        Line 3
        """
        let items = ActionItemParser.parse(markdown)
        #expect(items.count == 1)
        #expect(items[0].lineNumber == 2)
    }

    @Test func testKeyStability() {
        let items = ActionItemParser.parse("- [ ] Do something")
        #expect(items[0].key == "do something")
    }

    // MARK: - #85: lines without checkbox patterns are skipped

    @Test func testNonMatchingLinesAreIgnored() {
        // A paragraph of regular prose, headings, bullets, and dividers must
        // produce zero action items — only checkbox lines like "- [ ]", "* [ ]",
        // and "- [x]" match. Guards against the parser accidentally treating
        // plain bullets or headings as tasks.
        let markdown = """
        # Meeting Notes

        We discussed the roadmap and the Q4 OKRs.

        - Attendees: Alice, Bob, Carol
        - Date: 2026-07-18

        ---

        ## Discussion
        * Topic A: backend refactor
        - Topic B: launch timeline

        Action item: ship the release (no checkbox, just prose)
        TODO: refactor the API (no dash prefix)
        """
        let items = ActionItemParser.parse(markdown)
        #expect(items.isEmpty, "Non-checkbox lines should produce no action items — got \(items)")
    }
}
