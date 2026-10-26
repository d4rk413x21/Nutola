import Foundation
import Testing
@testable import Nutola

struct ClaudeDesktopTests {
    @Test func testNewChatURLSchemeHostPath() {
        let url = ClaudeDesktop.newChatURL(prompt: "hello")!
        #expect(url.scheme == "claude")
        #expect(url.host == "claude.ai")
        #expect(url.path == "/new")
    }

    @Test func testNewChatURLPercentEncodesSpecialCharacters() {
        let prompt = #"Hello, world! Use tool: get_meeting id=abc&def #tag "quoted" 100%"#
        let url = ClaudeDesktop.newChatURL(prompt: prompt)!
        #expect(url.absoluteString == #"claude://claude.ai/new?q=Hello,%20world!%20Use%20tool:%20get_meeting%20id%3Dabc%26def%20%23tag%20%22quoted%22%20100%25"#)
    }

    @Test func testNewChatURLEncodesPlusSign() {
        // "C++ migration" must not arrive with a raw + that a form-decoder reads as a space.
        let url = ClaudeDesktop.newChatURL(prompt: "C++ migration")!
        #expect(url.absoluteString.contains("C%2B%2B"))
        #expect(!(url.query!.contains("+")))
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        #expect(decoded == "C++ migration")
    }

    @Test func testNewChatURLRoundTripsOrdinaryPrompt() {
        let prompt = "What did we decide about the Q3 launch?"
        let url = ClaudeDesktop.newChatURL(prompt: prompt)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        #expect(decoded == prompt)
    }

    @Test func testNewChatURLTruncatesLongPrompts() {
        let huge = String(repeating: "a", count: ClaudeDesktop.maxPromptLength + 500)
        let url = ClaudeDesktop.newChatURL(prompt: huge)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        #expect(decoded?.count == ClaudeDesktop.maxPromptLength)
    }

    @Test func testNewChatURLHandlesEmptyPrompt() {
        let url = ClaudeDesktop.newChatURL(prompt: "")
        #expect(url?.query == "q=")
    }

    @Test func testMeetingPromptCarriesTitleIdAndQuestion() {
        let id = UUID()
        let prompt = ClaudeDesktopPrompt.meeting(id: id, title: "Roadmap sync", question: "What did we decide?")
        #expect(prompt.contains("Nutola meeting"))
        #expect(prompt.contains("Roadmap sync"))
        #expect(prompt.contains(id.uuidString))
        #expect(prompt.contains("What did we decide?"))
    }

    @Test func testMeetingPromptFallsBackOnEmptyQuestion() {
        let prompt = ClaudeDesktopPrompt.meeting(id: UUID(), title: "1:1", question: "   ")
        #expect(!(prompt.contains("Question: \n")))
        #expect(prompt.contains("overview"))
    }

    @Test func testLibraryPromptCarriesQuestion() {
        let prompt = ClaudeDesktopPrompt.library(question: "When did I last talk about hiring?")
        #expect(prompt.contains("Nutola meetings"))
        #expect(prompt.contains("When did I last talk about hiring?"))
    }

    @Test func testLibraryPromptFallsBackOnEmptyQuestion() {
        let prompt = ClaudeDesktopPrompt.library(question: "")
        #expect(prompt.contains("talking about"))
    }

    @Test func testLivePromptDefaultsAndCarriesQuestion() {
        #expect(ClaudeDesktopPrompt.live(question: "") == "I'm in a Nutola meeting happening right now — What's being discussed, and is there anything I should add or ask?")
        #expect(ClaudeDesktopPrompt.live(question: "Summarize the last 5 minutes") == "I'm in a Nutola meeting happening right now — Summarize the last 5 minutes")
    }

    // MARK: - ClaudeCode (claude://code/new) deep links

    @Test func testCodeSessionURLSchemeHostPath() {
        let url = ClaudeCode.codeSessionURL(prompt: "hello", folder: "/Users/me/repo")!
        #expect(url.scheme == "claude")
        #expect(url.host == "code")
        #expect(url.path == "/new")
    }

    @Test func testCodeSessionURLCarriesPromptAndFolder() {
        let url = ClaudeCode.codeSessionURL(prompt: "install gh", folder: "/Users/me")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "q" })?.value == "install gh")
        #expect(items.first(where: { $0.name == "folder" })?.value == "/Users/me")
    }

    @Test func testCodeSessionURLOmitsFolderWhenNil() {
        let url = ClaudeCode.codeSessionURL(prompt: "hi", folder: nil)!
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        #expect(!(names.contains("folder")))
    }

    @Test func testCodeSessionURLEncodesPlusSign() {
        let url = ClaudeCode.codeSessionURL(prompt: "C++ migration", folder: nil)!
        #expect(url.absoluteString.contains("C%2B%2B"))
        #expect(!(url.query!.contains("+")))
    }

    @Test func testCodeSessionURLTruncatesLongPrompts() {
        let huge = String(repeating: "a", count: ClaudeDesktop.maxPromptLength + 500)
        let url = ClaudeCode.codeSessionURL(prompt: huge, folder: nil)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        #expect(decoded?.count == ClaudeDesktop.maxPromptLength)
    }
}
