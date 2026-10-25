# Nutola

Record meetings on macOS, transcribe them on device, and turn spoken development
requests into reviewed tasks and Linear issues.

## Requirements

- macOS 26 or later on Apple Silicon.
- Microphone and system audio recording permissions. Calendar access is optional.
- Apple Intelligence for on-device summaries, or a configured AI CLI.
- Claude Code, Codex, OpenCode or Mistral Vibe for task extraction. Sign in and
  configure the chosen CLI before selecting it in **Settings → Intelligence**.

Claude and Codex binaries bundled with VS Code and VS Code Insiders are also detected.
OpenCode and Mistral Vibe use their configured account and model.

## Install

Download `Nutola.zip` from this repository's [releases](https://github.com/d4rk413x21/Nutola/releases),
extract it, and move `Nutola.app` to Applications.

For a preview build without installing Xcode locally, open **Actions → CI → Run workflow**
in this repository. Once it finishes, download the **Nutola-preview** artifact and extract
`Nutola.zip`. Builds are ad-hoc signed; macOS may ask you to allow the app to open.

Open Nutola from Applications and complete the permissions walkthrough.

## Meeting → tasks → Linear

1. Record a meeting from the menu bar, or let meeting detection offer to record it.
2. Wait for transcription, then review speaker names and transcript text.
3. Open **Development tasks**, choose a CLI, and select **Extract tasks**.
4. Review the titles, descriptions, owners and quoted evidence. **Save & Close**
   keeps the drafts with the meeting; **Copy selected drafts** copies Markdown.
5. To create issues, connect a personal Linear API key in **Settings → Integrations**.
   Choose a **Team**, optionally a **Project**, select the drafts and press
   **Create / retry issues**.

The key needs read access to teams, projects and issues, plus permission to create issues.
Owner names stay in the descriptions; Nutola does not guess Linear assignees.
Each successful issue gets a saved link. Retry checks its stable ID first to recover
from timeouts or partial failures. Existing issues are edited in Linear.
Pending and created task records are retained, so removal and re-extraction are disabled
after an export starts. Retry recovers an existing issue's link without applying further
draft edits. Disconnecting Linear keeps the issues and their saved links.

## Notes and storage

Edit meeting titles, transcripts, speakers and notes in the app. Templates are available
in **Settings → Templates**. Calendar integration and folders help organize recurring meetings.

Recordings, transcripts, notes and task drafts live in
`~/Library/Application Support/Nutola/` as audio, JSON and Markdown files.

The app identifier is `io.github.d4rk413x21.Nutola`. On the first launch of this build,
previous app preferences are imported without overwriting new preferences. The Linear API key
must be entered again, and macOS may ask for recording or calendar permissions again.
The meeting archive stays in the same location.

## Privacy

- Recording and transcription happen on your Mac; models may be downloaded when needed.
- Choosing an AI CLI sends meeting text through that CLI's configured account and model.
- Linear receives only selected draft descriptions and their quoted transcript passages.
  The API key is stored in the macOS login Keychain. Connecting loads workspace/team
  metadata, and choosing a team loads its projects.
- Sharing is optional. Published GitHub gists are unlisted, not private. Local HTML,
  Markdown and PDF exports are also available.

## CLI and MCP

The installed app includes a read-only CLI:

```bash
/Applications/Nutola.app/Contents/MacOS/Nutola meetings help
```

For assistant access to the meeting library, use the connector setup in
**Settings → Intelligence**. The same binary runs the MCP server with `--mcp`.
MCP includes editing and deletion tools, so review the permissions granted to your assistant.

## Build from source

Building locally requires Xcode 26.6 and its command-line tools. Alternatively, use
GitHub Actions as described above.

```bash
git clone https://github.com/d4rk413x21/Nutola.git
cd Nutola
make install  # build, package and install /Applications/Nutola.app
swift test    # run the test suite
```

`make app` assembles `dist/Nutola.app`. Publishing a version tag as a GitHub release
runs **Release app**, which attaches `Nutola.zip` to that release.

## Acknowledgements

- Based on [conrad-vanl/parfait](https://github.com/conrad-vanl/parfait), which provided
  the original architecture, audio/transcription pipeline and design.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) provides speaker
  diarization. Its model weights (CC-BY-4.0) derive from
  [pyannote](https://github.com/pyannote/pyannote-audio) and
  [WeSpeaker](https://github.com/wenet-e2e/wespeaker).
- [Granola](https://granola.ai) inspired the meeting notes experience.
- The Soniqo model weights are also used by [anarlog](https://github.com/fastrepl/anarlog).

## License

[MIT](LICENSE). Original copyright and attribution notices are retained.
