import Foundation

/// Renders a meeting's notes as a single self-contained, read-only HTML page
/// (inline CSS, no external assets) with a dark theme by default. The page
/// carries the meeting title and date, the summary (markdown → basic HTML),
/// action items as a checkbox list, and the speaker-labeled transcript.
///
/// `exportHTML` is the pure renderer; `exportToFile` and `publishToGist` are the
/// convenience flows that write the page to a temp file or publish it through
/// `GitHubGist`.
enum SharedNotesExporter {
    /// Renders the shared-notes HTML page for the given meeting.
    static func exportHTML(
        meeting: Meeting,
        summary: String,
        transcript: [TranscriptTurn],
        actionItems: [ActionItem]
    ) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let title = escape(meeting.title)
        let date = escape(df.string(from: meeting.createdAt))
        let duration = escape(TemplateRenderer.duration(meeting.duration))

        let summaryBody = renderMarkdown(TemplateRenderer.fill(summary, meeting: meeting))
        let summaryBlock = summaryBody.isEmpty ? "" : """
        <h2 class="section-title">Summary</h2>
        <section class="card">
        \(summaryBody)
        </section>
        """

        let itemsBlock: String
        if actionItems.isEmpty {
            itemsBlock = ""
        } else {
            let list = actionItems.map { item -> String in
                let label = escape(item.text) + (item.owner.map { " — \(escape($0))" } ?? "")
                return """
                <li class="task"><input type="checkbox" disabled\(item.isChecked ? " checked" : "")> \(label)</li>
                """
            }.joined(separator: "\n")
            itemsBlock = """
            <h2 class="section-title">Action items</h2>
            <section class="card">
            <ul>
            \(list)
            </ul>
            </section>
            """
        }

        let turns = transcriptTurns(turns: transcript, speakers: meeting.speakers)
        let transcriptBlock = turns.isEmpty ? "" : """
        <h2 class="section-title">Transcript</h2>
        <section class="card">
        \(turns)
        </section>
        """

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark">
        <meta name="generator" content="nutola/1">
        <title>\(title)</title>
        <style>
        :root{
          --page:#1C1B1F; --card:#2A2831; --accent:#F0A95B; --honey:#F2B24F;
          --link:#9FB4FF; --ink:#F2EAE0; --muted:rgba(242,234,224,.6);
          --border:rgba(242,234,224,.12); --chip:rgba(240,169,91,.14);
          --bg:#141316;
        }
        *{box-sizing:border-box}
        body{
          margin:0; background:var(--bg); color:var(--ink);
          font:16px/1.65 ui-rounded,"SF Pro Rounded",-apple-system,system-ui,"Segoe UI",sans-serif;
          -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
        }
        main{max-width:720px; margin:0 auto; padding:44px 24px 56px}
        .nutola-bar{
          height:6px; border-radius:3px; margin-bottom:30px;
          background:linear-gradient(90deg,#F0A95B 0 25%,#F2B24F 25% 50%,#9FB4FF 50% 75%,#F2EAE0 75% 100%);
          box-shadow:inset 0 0 0 1px var(--border);
        }
        header h1{margin:0 0 10px; font-size:2.1rem; line-height:1.15; letter-spacing:-.015em; color:var(--accent)}
        .meta{color:var(--muted); font-size:.95rem}
        .section-title{
          margin:36px 0 12px; color:var(--honey); font-size:.78rem; font-weight:700;
          text-transform:uppercase; letter-spacing:.14em;
        }
        .card{
          background:var(--card); border-radius:16px; padding:26px 30px;
          box-shadow:inset 0 0 0 1px var(--border); overflow-x:auto;
        }
        .card h1{margin:.2em 0 .5em; font-size:1.3rem; color:var(--accent)}
        .card h2{margin:1.5em 0 .5em; font-size:1.02rem; color:var(--accent)}
        .card h1:first-child,.card h2:first-child{margin-top:.1em}
        .card h3{margin:1.2em 0 .4em; font-size:.95rem}
        .card p{margin:.55em 0}
        .card ul{margin:.55em 0; padding-left:1.4em}
        .card li{margin:.3em 0}
        li.task{list-style:none; margin-left:-1.4em}
        input[type=checkbox]{accent-color:var(--accent); pointer-events:none; vertical-align:-2px; margin-right:6px}
        a{color:var(--link)}
        .turn{padding:16px 0; border-top:1px solid var(--border)}
        .turn:first-child{border-top:none; padding-top:2px}
        .turn:last-child{padding-bottom:2px}
        .speaker{font-weight:700}
        .time{margin-left:10px; color:var(--muted); font-size:.82rem; font-variant-numeric:tabular-nums}
        .turn p{margin:6px 0 0}
        footer{
          margin-top:44px; padding-top:18px; border-top:1px solid var(--border);
          text-align:center; color:var(--muted); font-size:.85rem;
        }
        footer a{font-weight:600; text-decoration:none}
        @media (max-width:540px){
          main{padding:28px 16px 40px}
          header h1{font-size:1.6rem}
          .card{padding:20px 18px}
        }
        </style>
        </head>
        <body>
        <main>
        <div class="nutola-bar"></div>
        <header>
        <h1>\(title)</h1>
        <div class="meta">\(date) · \(duration)</div>
        </header>
        \(summaryBlock)
        \(itemsBlock)
        \(transcriptBlock)
        <footer>Shared via <a href="\(AppIdentity.repositoryURL.absoluteString)">Nutola</a></footer>
        </main>
        </body>
        </html>
        """
    }

    /// Writes the shared-notes HTML to a temp file and returns its URL.
    static func exportToFile(
        meeting: Meeting,
        summary: String,
        transcript: [TranscriptTurn],
        actionItems: [ActionItem]
    ) throws -> URL {
        let html = exportHTML(meeting: meeting, summary: summary, transcript: transcript, actionItems: actionItems)
        let safeName = meeting.title.replacingOccurrences(of: "/", with: "-")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nutola — \(safeName) — \(UUID().uuidString).html")
        guard let data = html.data(using: .utf8) else {
            throw GistError.failed("Could not encode shared notes HTML as UTF-8.")
        }
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Publishes the shared-notes HTML as a secret gist and returns the
    /// rendered (notes.nutola.to) URL. Requires `gh` to be installed and
    /// authenticated.
    static func publishToGist(
        meeting: Meeting,
        summary: String,
        transcript: [TranscriptTurn],
        actionItems: [ActionItem]
    ) async throws -> URL {
        let html = exportHTML(meeting: meeting, summary: summary, transcript: transcript, actionItems: actionItems)
        let (_, rendered) = try await GitHubGist.publish(
            html: html,
            filename: "notes.html",
            description: "Nutola shared notes — \(meeting.title)")
        return rendered
    }

    // MARK: - Markdown

    /// Minimal markdown subset: #/##/### headings, paragraphs (blank-line
    /// separated), **bold**, *italic*, "- " bullets, "- [ ]"/"- [x]"
    /// checkboxes, and `---` horizontal rules. Anything else becomes paragraph
    /// text. Input is escaped, so model output can't inject markup.
    static func renderMarkdown(_ md: String) -> String {
        var blocks: [String] = []
        var paragraph: [String] = []
        var items: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append("<p>\(paragraph.joined(separator: " "))</p>")
            paragraph.removeAll()
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append("<ul>\n\(items.joined(separator: "\n"))\n</ul>")
            items.removeAll()
        }

        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushList()
            } else if line.hasPrefix("### ") {
                flushParagraph()
                flushList()
                blocks.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("## ") {
                flushParagraph()
                flushList()
                blocks.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                flushParagraph()
                flushList()
                blocks.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flushParagraph()
                let checked = !line.hasPrefix("- [ ] ")
                items.append("<li class=\"task\"><input type=\"checkbox\" disabled\(checked ? " checked" : "")> \(inline(String(line.dropFirst(6))))</li>")
            } else if line.hasPrefix("- ") {
                flushParagraph()
                items.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else if isHorizontalRule(line) {
                flushParagraph()
                flushList()
                blocks.append("<hr>")
            } else {
                flushList()
                paragraph.append(inline(line))
            }
        }
        flushParagraph()
        flushList()
        return blocks.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    private static func inline(_ s: String) -> String {
        var out = escape(s)
        out = out.replacing(#/\*\*(\S[^*]*\S|\S)\*\*/#) { "<strong>\($0.1)</strong>" }
        out = out.replacing(#/\*(\S[^*]*\S|\S)\*/#) { "<em>\($0.1)</em>" }
        return out
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let char = compact.first else { return false }
        guard char == "-" || char == "*" || char == "_" else { return false }
        return compact.allSatisfy { $0 == char }
    }

    /// Speaker-labeled turns with timestamps, mirroring HTMLExporter's turn
    /// block but consuming pre-built `[TranscriptTurn]` values directly.
    private static func transcriptTurns(turns: [TranscriptTurn], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var out: [String] = []
        for turn in turns {
            let who = escape(names[turn.speakerID] ?? turn.speakerID)
            out.append("""
            <div class="turn">
            <div class="turn-head"><span class="speaker">\(who)</span><span class="time">\(MeetingArchive.timestamp(turn.start))</span></div>
            <p>\(escape(turn.text))</p>
            </div>
            """)
        }
        return out.joined(separator: "\n")
    }
}
