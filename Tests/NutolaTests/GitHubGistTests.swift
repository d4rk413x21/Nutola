import Foundation
import Testing
@testable import Nutola

struct GitHubGistTests {
    private let sha = "abcdef0123456789abcdef0123456789abcdef01"

    // MARK: - renderedURL (opaque notes.nutola.to token)

    // Golden tokens below MUST match the Worker's decoder byte-for-byte
    // (workers/notes-proxy/src/index.js + test). Regenerate both together if the
    // wire format ever changes.

    @Test func testMapsModernThirtyTwoHexGist() {
        let raw = "https://gist.githubusercontent.com/sample-user/" +
            "0123456789abcdef0123456789abcdef/raw/\(sha)/meeting.html"
        #expect(GitHubGist.renderedURL(fromRaw: raw)?.absoluteString == "https://notes.nutola.to/C3NhbXBsZS11c2VyASNFZ4mrze8BI0VniavN76vN7wEjRWeJq83vASNFZ4mrze8B")
    }

    @Test func testMapsLegacyTwentyHexGist() {
        let raw = "https://gist.githubusercontent.com/sample-user/" +
            "0123456789abcdef0123/raw/\(sha)/meeting.html"
        #expect(GitHubGist.renderedURL(fromRaw: raw)?.absoluteString == "https://notes.nutola.to/C3NhbXBsZS11c2VyASNFZ4mrze8BI6vN7wEjRWeJq83vASNFZ4mrze8B")
    }

    @Test func testRenderedTokenRoundTripsToGistCoordinates() {
        let raw = "https://gist.githubusercontent.com/sample-user/" +
            "0123456789abcdef0123456789abcdef/raw/\(sha)/meeting.html"
        let token = GitHubGist.renderedURL(fromRaw: raw)!.lastPathComponent
        #expect(GistLinkToken.decode(token) == GistLinkToken.Decoded(
                user: "sample-user",
                gistID: "0123456789abcdef0123456789abcdef",
                sha: sha))
    }

    @Test func testRenderedURLRejectsNonGistRawURLs() {
        // Empty (the shape publish() sees when gh's raw_url lookup comes back blank).
        #expect(GitHubGist.renderedURL(fromRaw: "") == nil)
        #expect(GitHubGist.renderedURL(fromRaw: "https://example.com/foo") == nil)
        // Wrong host.
        #expect(GitHubGist.renderedURL(
            fromRaw: "https://gist.github.com/sample-user/0123456789abcdef0123/raw/\(sha)/meeting.html") == nil)
        // SHA too short.
        #expect(GitHubGist.renderedURL(
            fromRaw: "https://gist.githubusercontent.com/sample-user/0123456789abcdef0123/raw/abcd/meeting.html") == nil)
    }

    // MARK: - GistLinkToken

    @Test func testTokenRoundTripsUppercaseUser() {
        let decoded = GistLinkToken.Decoded(
            user: "Some-User", gistID: "0123456789abcdef0123456789abcdef", sha: sha)
        let token = GistLinkToken.encode(user: decoded.user, gistID: decoded.gistID, sha: decoded.sha)!
        #expect(GistLinkToken.decode(token) == decoded)
    }

    @Test func testTokenEncodeRejectsBadInput() {
        // Non-hex / odd-length gist id.
        #expect(GistLinkToken.encode(user: "u", gistID: "xyz", sha: sha) == nil)
        // SHA that isn't 20 bytes.
        #expect(GistLinkToken.encode(user: "u", gistID: "0123456789abcdef0123", sha: "abcd") == nil)
    }

    @Test func testTokenDecodeRejectsGarbage() {
        #expect(GistLinkToken.decode("!!!not-base64!!!") == nil)
        #expect(GistLinkToken.decode("") == nil)
    }
}
