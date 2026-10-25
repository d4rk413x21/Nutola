<p align="center">
  <img src="Resources/AppIcon-1024.png" style="border-radius: 20px" width="140" alt="Nutola icon — a layered nutola glass">
</p>

<h1 align="center">Nutola</h1>

<p align="center"><em>Layered meeting notes. Perfectly local.</em></p>

<p align="center">
An open-source, on-device meeting notetaker for macOS — a lightweight alternative to Granola.<br>
It lives in your menu bar, notices when a meeting starts, records both sides of the call,<br>
and writes a transcript with named speakers plus templated notes — without audio ever leaving your Mac.<br>
Then it hands meeting text to <strong>your assistant</strong> — Apple Intelligence, Claude, Codex, OpenCode,
or Mistral Vibe — through on-device analysis, your configured CLI, or the built-in MCP server.
</p>

---

## What it does

- **Auto-detects meetings.** When Zoom, Meet, Teams, FaceTime — anything — starts using your
  microphone, Nutola offers to record (or just starts, if you tell it to). Manual recording is
  one click in the menu bar.
- **Records both sides.** Your mic through AVAudioEngine; everyone else through a Core Audio
  process tap on system audio. No virtual audio drivers, no kernel extensions, no bots joining
  your calls.
- **Transcribes on device** with Apple's SpeechAnalyzer (the macOS 26 speech engine) — with
  per-segment timestamps.
- **Names the speakers.** You're "you" (mic channel); remote voices are separated with a small
  on-device diarization model ([FluidAudio](https://github.com/FluidInference/FluidAudio), ~22 MB,
  downloaded once). Calendar attendees are offered as rename suggestions, and renaming a speaker
  fixes the whole transcript.
- **Summarizes on device** with Apple Intelligence (FoundationModels), following **your**
  editable markdown templates. Long meetings map-reduce through the model; meetings too big for
  it route to your own Claude or Codex account.
- **Drafts notes live.** While a meeting is still recording, Nutola streams a first-pass summary
  from the live transcript so notes appear within seconds — then refines them after the call ends.
- **Everything is editable** — title, notes, transcript, speakers, with full edit history.
- **Calendar-aware.** With Calendar access, **Coming up** shows your agenda, pre-fills titles and
  attendees when you record, and offers one-click join links (Zoom, Meet, Teams, Webex). A menu-bar
  countdown can remind you before the next event.
- **Folders for recurring meetings.** Group standups, 1:1s, and project syncs into folders. Assign
  from the sidebar, drag-and-drop, or **Add to folder** on an upcoming event — future recordings
  with the same calendar title land in the same folder automatically.
- **Ask live, mid-meeting.** A floating card shows the transcript as it happens; one button opens
  your assistant on the call in progress. Nutola exposes the running transcript through a
  `get_live_transcript` MCP tool, so you can ask "what did I miss?" or "what should I ask next?"
  — no pasting, and it rides over full-screen Zoom.
- **Ask about one meeting or all of them.** The **Ask** screen answers in-app (Apple Intelligence)
  or opens Claude / Codex with your meeting library loaded through Nutola's MCP connector — nothing
  is copied in. Once connected, you can skip the app entirely and just ask your assistant anytime.
- **Regenerate and edit notes through MCP.** Claude or Codex can regenerate a meeting's notes against
  a different template, or edit them directly, through the same server.
- **Publish** a beautiful self-contained page (notes + transcript) as a secret gist on your own
  GitHub (`gh`), with a rendered share URL served back by the bundled notes-proxy worker — or
  preview/export the HTML locally with no dependencies at all.
- **Crash diagnostics (opt-in).** When enabled, Nutola records a scrubbed crash report (never audio,
  transcript, or notes) on both uncaught exceptions and fatal signals, kept as a capped history and
  viewable in Settings → Debug → Crash history.
- **Plain files, no database.** Every meeting is a folder of JSON + Markdown + m4a in
  `~/Library/Application Support/Nutola`. Your data is greppable, backupable, yours.

## The stack is the feature

Nutola has no backend, no accounts, and no API keys. It composes things your Mac already has:

| Need | Provider |
|---|---|
| Meeting detection | Core Audio process objects (mic-in-use by other apps) |
| System-audio capture | Core Audio process taps (macOS 14.4+) |
| Transcription | SpeechAnalyzer / SpeechTranscriber (macOS 26, on device) |
| Speaker separation | FluidAudio CoreML diarization (on device) |
| Summaries, titles | Apple Intelligence FoundationModels (on device), or your selected CLI assistant |
| Long meeting summaries | **Your own** Claude, Codex, OpenCode, or Mistral Vibe CLI configuration |
| Ask (per-meeting, cross-meeting, live) | **Apple Intelligence** or your selected CLI in-app; Claude / Codex also support desktop handoff |
| Calendar | EventKit (on device) |
| Publish target | **Your own** GitHub via `gh` (secret gist), served back rendered by the bundled notes-proxy worker, or a local browser preview / HTML export |

## Requirements

- **macOS 26 (Tahoe)** on Apple Silicon
- **Apple Intelligence enabled** (Settings → Apple Intelligence & Siri) for on-device summaries
  and in-app Ask
- **Optional — Claude:** [Claude Desktop](https://claude.ai/download) or
  [Claude Code](https://claude.com/claude-code) (`claude` CLI, logged in) — for cloud Ask and
  long-meeting summaries, billed to your own plan
- **Optional — Codex:** [Codex](https://chatgpt.com/codex) (`codex` CLI, logged in) — same as
  Claude, through your own account
- **Optional — OpenCode:** [OpenCode](https://opencode.ai/docs/) (`opencode` CLI), configured
  with your preferred account and model
- **Optional — Mistral Vibe:** [Mistral Vibe](https://github.com/mistralai/mistral-vibe)
  (`vibe` CLI), with its account and model configured
- **Optional:** [GitHub CLI](https://cli.github.com) (`gh auth login`) — to publish a shareable
  rendered URL as a gist on your own account (without it, you can still preview and export the
  HTML locally)

Claude and Codex executables bundled with VS Code and VS Code Insiders are also detected under
`~/.vscode/extensions` and `~/.vscode-insiders/extensions`. Nutola chooses the newest executable
bundle compatible with the Mac's architecture when a standalone install is not found. The
resolved executable is used for requests, version checks, and account checks.

For OpenCode or Mistral Vibe, run `opencode` or `vibe` in Terminal once to finish account/model
setup, then select it in **Settings → Intelligence**. These providers answer inside Nutola;
meeting text is included directly, so no Nutola MCP connector is required. The installed status
indicates that the executable was found; authentication/model errors are reported on requests.

## Install

```bash
git clone https://github.com/matheusgois-dd/Nutola.git
cd nutola
make install        # builds, assembles Nutola.app, copies to /Applications
open /Applications/Nutola.app
```

Look for the nutola glass in your menu bar. A first-run onboarding walkthrough covers permissions
and optional setup. On first recording, macOS will ask for **Microphone** and **System Audio
Recording** permission (the latter lives under Privacy & Security → Screen & System Audio
Recording → "System Audio Recording Only").

> **Signing note:** `make install` ad-hoc signs with a stable designated requirement, so TCC
> permissions survive rebuilds. If you have an Apple Development certificate, prefer
> `make install SIGN_ID="Apple Development: you@example.com (TEAMID)"`.

## Connect your assistant to your meeting library

Pick your assistant in **Settings → Intelligence**. For Claude or Codex, add the Nutola MCP
connector once — the app has one-click setup buttons, or run it yourself:

### Read meetings from the CLI

The installed app binary also exposes a read-only CLI. This works without MCP discovery and reads
the same local archive as the app:

```bash
NUTOLA=/Applications/Nutola.app/Contents/MacOS/Nutola

$NUTOLA meetings list --limit 20 --offset 0
$NUTOLA meetings search device token --limit 20 --offset 0
$NUTOLA meetings show 123E4567-E89B-12D3-A456-426614174000
$NUTOLA meetings transcript 123E4567-E89B-12D3-A456-426614174000
$NUTOLA meetings live                 # most recent six minutes
$NUTOLA meetings live --minutes 0     # whole live meeting
$NUTOLA meetings help
```

`list` and `search` print `next_offset` when another page is available. Limits are clamped to
`1...200`; offsets and live-minute windows must be non-negative. Successful results are written to
stdout. Invalid commands and missing meetings are written to stderr with a non-zero exit status.
The CLI cannot edit summaries, templates, transcripts, or meetings. The existing `--mcp` server
remains available for read and write integrations.

### Claude Code

```bash
claude mcp add nutola -s user -- "/Applications/Nutola.app/Contents/MacOS/Nutola" --mcp
```

### Codex

```bash
codex mcp add nutola -- "/Applications/Nutola.app/Contents/MacOS/Nutola" --mcp
```

Then from any session (or the desktop app with the same server):

> "Search my meetings for when I last discussed hiring, and summarize what was decided."

The MCP server (`Nutola --mcp`) speaks stdio over your on-disk library. Read tools:
`list_meetings` (paginated via `limit`/`offset`), `search_meetings` (paginated),
`get_meeting`, `get_transcript`, and `get_live_transcript`
(the meeting in progress). Edit tools: `regenerate_summary`, `update_summary`,
`delete_meeting`, and the template
tools (`list_templates`, `get_template`, `create_template`, `update_template`, `rename_template`,
`delete_template`). Nothing leaves your Mac except what the model reads or writes through them.

### Claude Desktop

Claude Desktop reads MCP servers from a config file, not a CLI command. Open (or create)
`~/Library/Application Support/Claude/claude_desktop_config.json` and merge this into the
`mcpServers` object — **don't overwrite the file** if you already have other servers configured:

```json
{
  "mcpServers": {
    "nutola": {
      "command": "/Applications/Nutola.app/Contents/MacOS/Nutola",
      "args": ["--mcp"]
    }
  }
}
```

Restart Claude Desktop after saving. Settings → Intelligence has "Add to Claude Code" and
"Add to Claude Desktop" buttons, plus "Copy JSON" and "Reveal in Finder" for manual setup.

### Codex

Codex stores MCP servers in `~/.codex/config.toml`. Settings → Intelligence has an "Add with
Codex" button, or run the `codex mcp add` command above. Use `$nutola` (not `@`) to attach
the connector in Codex prompts.

## Templates

Notes are shaped by markdown templates you can edit in **Settings → Templates** (or any editor —
they're just files in `~/Library/Application Support/Nutola/Templates/`). Headings guide the
model; prose under a heading tells it what belongs there. Placeholders: `{{title}}`, `{{date}}`,
`{{attendees}}`, `{{duration}}`, `{{app}}`. Ships with **Meeting Notes**, **1-on-1**, and
**Interview**.

## Privacy model

- Audio, transcripts, and notes never leave your Mac by default.
- The only network calls Nutola itself makes: one-time model downloads (Apple speech assets via
  the OS; the diarization model from Hugging Face).
- Anything involving Claude, Codex, OpenCode, Mistral Vibe, or GitHub happens through **your** configured
  CLIs, at your explicit request (chat, publish, or when a meeting exceeds the on-device model),
  on your own accounts.
- Publishing is always an explicit action. "Secret" gists are unlisted (on your own account,
  deletable) — anyone with the link can view the page; the browser preview and HTML export never
  leave your Mac.

## Development task drafts

Open a processed meeting and choose **Development tasks**. Select Claude, Codex, OpenCode,
or Mistral Vibe CLI, then **Extract tasks**. The full saved transcript is analyzed in parts; later parts
can refine or cancel earlier requests. Each draft includes editable text, an optional owner,
and original transcript passages with speaker names and timestamps. Unassigned work stays
unassigned.

Drafts are saved alongside the meeting in `development-tasks.json`. Re-extracting asks before
replacing edits; failures and cancellation keep existing drafts. A warning appears if the
transcript has changed since extraction. Select drafts and use **Copy selected drafts** to
copy their descriptions and evidence for use in Linear. This workflow prepares local drafts;
it does not create Linear issues.

Extraction sends the transcript through the selected CLI account. Claude runs without tools;
Codex uses an isolated read-only invocation without user configuration, connectors, or shell
tools. OpenCode uses a dedicated analysis agent with tools denied; Vibe disables tools for the
headless request. Both reuse the CLI's configured model and account. A recent Codex CLI supporting `--ignore-user-config` is required. No API key is added
to Nutola.

## Development

```bash
swift build          # debug build
swift test           # 269 unit tests (store, folders, labeling, formatting, templates, MCP, HTML, live transcription, calendar, Claude/Codex deep-links, pipeline, edit history, crash diagnostics, CLI args)
make app             # assemble dist/Nutola.app
make app-icon        # regenerate the app icon from scripts/MakeIcon.swift
make nav-icon        # regenerate the menu-bar nav icon
```

```
Sources/Nutola/
  Domain/          Protocols (repositories, services) + use cases (SRP, testable business logic)
  Data/            Repository adapters + service implementations (file, EventKit, audio, AI)
  UI/              SwiftUI views and components
  Audio/           MeetingDetector · MicRecorder · SystemAudioTap · RecordingSession
  Transcription/   Transcriber · Diarizer · SpeakerLabeler
  Intelligence/    AppleSummarizer · ClaudeCLI · CodexCLI · TemplateStore
  Calendar/        CalendarStore · UpcomingMeetings · ConferenceJoiner
  Store/           Domain models · MeetingArchive · folders
  MCP/             stdio MCP server (--mcp)
  Publish/         HTMLExporter · GitHubGist
  App/             DependencyContainer · AppState (coordinator) · ProcessingPipeline · CrashDiagnosticLog
workers/notes-proxy/  Cloudflare Worker that serves published gists back rendered
```

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) for CoreML speaker
  diarization; model weights (CC-BY-4.0) derive from
  [pyannote](https://github.com/pyannote/pyannote-audio) and
  [WeSpeaker](https://github.com/wenet-e2e/wespeaker).
- [Granola](https://granola.ai) for showing how good meeting notes can feel.
- This project started as a fork of [conrad-vanl/parfait](https://github.com/conrad-vanl/parfait) —
  the original on-device meeting notetaker. Full credit for the architecture, audio/transcription
  pipeline, and design goes to its author.

## License

[MIT](LICENSE)
