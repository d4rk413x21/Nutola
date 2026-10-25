import XCTest
@testable import Nutola

final class GitHubGistTests: XCTestCase {
    private let sha = "abcdef0123456789abcdef0123456789abcdef01"

    // MARK: - renderedURL (opaque notes.nutola.to token)

    // Golden tokens below MUST match the Worker's decoder byte-for-byte
    // (workers/notes-proxy/src/index.js + test). Regenerate both together if the
    // wire format ever changes.

    func testMapsModernThirtyTwoHexGist() {
        let raw = "https://gist.githubusercontent.com/sample-user/" +
            "0123456789abcdef0123456789abcdef/raw/\(sha)/meeting.html"
        XCTAssertEqual(
            GitHubGist.renderedURL(fromRaw: raw)?.absoluteString,
            "https://notes.nutola.to/C3NhbXBsZS11c2VyASNFZ4mrze8BI0VniavN76vN7wEjRWeJq83vASNFZ4mrze8B")
    }

    func testMapsLegacyTwentyHexGist() {
        let raw = "https://gist.githubusercontent.com/sample-user/" +
            "0123456789abcdef0123/raw/\(sha)/meeting.html"
        XCTAssertEqual(
            GitHubGist.renderedURL(fromRaw: raw)?.absoluteString,
            "https://notes.nutola.to/C3NhbXBsZS11c2VyASNFZ4mrze8BI6vN7wEjRWeJq83vASNFZ4mrze8B")
    }

    func testRenderedTokenRoundTripsToGistCoordinates() {
        let raw = "https://gist.githubusercontent.com/sample-user/" +
            "0123456789abcdef0123456789abcdef/raw/\(sha)/meeting.html"
        let token = GitHubGist.renderedURL(fromRaw: raw)!.lastPathComponent
        XCTAssertEqual(
            GistLinkToken.decode(token),
            GistLinkToken.Decoded(
                user: "sample-user",
                gistID: "0123456789abcdef0123456789abcdef",
                sha: sha))
    }

    func testRenderedURLRejectsNonGistRawURLs() {
        // Empty (the shape publish() sees when gh's raw_url lookup comes back blank).
        XCTAssertNil(GitHubGist.renderedURL(fromRaw: ""))
        XCTAssertNil(GitHubGist.renderedURL(fromRaw: "https://example.com/foo"))
        // Wrong host.
        XCTAssertNil(GitHubGist.renderedURL(
            fromRaw: "https://gist.github.com/sample-user/0123456789abcdef0123/raw/\(sha)/meeting.html"))
        // SHA too short.
        XCTAssertNil(GitHubGist.renderedURL(
            fromRaw: "https://gist.githubusercontent.com/sample-user/0123456789abcdef0123/raw/abcd/meeting.html"))
    }

    // MARK: - GistLinkToken

    func testTokenRoundTripsUppercaseUser() {
        let decoded = GistLinkToken.Decoded(
            user: "Some-User", gistID: "0123456789abcdef0123456789abcdef", sha: sha)
        let token = GistLinkToken.encode(user: decoded.user, gistID: decoded.gistID, sha: decoded.sha)!
        XCTAssertEqual(GistLinkToken.decode(token), decoded)
    }

    func testTokenEncodeRejectsBadInput() {
        // Non-hex / odd-length gist id.
        XCTAssertNil(GistLinkToken.encode(user: "u", gistID: "xyz", sha: sha))
        // SHA that isn't 20 bytes.
        XCTAssertNil(GistLinkToken.encode(user: "u", gistID: "0123456789abcdef0123", sha: "abcd"))
    }

    func testTokenDecodeRejectsGarbage() {
        XCTAssertNil(GistLinkToken.decode("!!!not-base64!!!"))
        XCTAssertNil(GistLinkToken.decode(""))
    }
}
