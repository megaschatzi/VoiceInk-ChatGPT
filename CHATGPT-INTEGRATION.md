# Native ChatGPT sign-in, audio transcription and text enhancement

This experimental VoiceInk implementation adds **both audio-to-text transcription
and optional LLM text enhancement using a ChatGPT account**. It does not require
an OpenAI API key or a locally installed Codex CLI. Users sign in through their
browser with a device code, then use the connection directly inside VoiceInk.

This is a development copy of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk),
not an official VoiceInk or OpenAI release. The purpose is to make the implementation
available for review and possible integration upstream. Repository visibility and
access permissions still apply to every link in this document.

## What is implemented

| Capability | Implementation |
| --- | --- |
| Sign in | Native device-code OAuth flow through OpenAI's sign-in page |
| Audio transcription | Recorded audio is sent directly to ChatGPT's dictation backend; the returned transcript enters VoiceInk's normal workflow |
| Optional text enhancement | The transcript and configured prompt are sent to the Codex Responses backend using the same account connection |
| Model choice | The enhancement model is configurable, including a custom model ID; access depends on the account |
| Credential storage | Separate, non-syncing macOS Keychain item, with token refresh and sign-out |
| Connection checks | Separate text-connection and audio-file tests in the ChatGPT provider panel |
| Existing settings | Import modes, prompts, shortcuts and dictionary entries through VoiceInk's existing settings backup tools |

**The audio transcription itself uses ChatGPT.** This is more than sending a
locally generated transcript to an LLM. Local transcription and other providers
remain available, but they are not required for the ChatGPT dictation path.

## End-to-end workflow

1. Open **Model Catalog → Cloud → ChatGPT** and sign in.
2. Select **ChatGPT Dictation** as the global or per-mode transcription model.
3. Record a dictation. VoiceInk sends the audio to OpenAI and receives the transcript.
4. If **AI Enhancement** is enabled, VoiceInk submits the transcript with the
   mode's prompt to the selected text model and returns the edited text.

Audio transcription and text enhancement are separate requests. Selecting a text
model such as `gpt-6.1-sol` does not select the speech-recognition model. ChatGPT's
dictation backend chooses that model; the implementation does not claim it is a
particular Whisper or Transcribe model. A custom text-model ID is not a guarantee
that an account can access it.

## Technical implementation

The connection follows the public Codex client's device-code OAuth protocol and
uses these routes:

- Authentication: device authorization and token exchange on `auth.openai.com`.
- Audio: `POST https://chatgpt.com/backend-api/transcribe`, with multipart audio.
- Text: `POST https://chatgpt.com/backend-api/codex/responses`, with a streaming
  Responses request, `store: false`, and the selected text model.

Both inference requests use the OAuth access token and account identifier from
the native login. There is no shell command, Python helper or CLI subprocess in
the app's ChatGPT request path. No user credentials are required for CI builds.

The text client parses server-sent events from raw bytes, preserving event
boundaries and UTF-8 text. It accepts valid streams even when the server omits the
`Content-Type` header, handles the final event at EOF, and rejects failed or
incomplete responses. Diagnostics contain bounded protocol metadata rather than
access tokens, prompts, transcripts or generated text.

The client retries a 401 once after refreshing the token. It does not automatically
retry 403 or 429 responses, switch accounts, or fall back to API billing.

### Where to review the code

- [OAuth, credentials and HTTP client](VoiceInk/Infrastructure/Providers/ChatGPT/ChatGPTClient.swift)
- [Protocol types, SSE parsing and safe diagnostics](VoiceInk/Infrastructure/Providers/ChatGPT/ChatGPTProtocol.swift)
- [Audio transcription provider](VoiceInk/Infrastructure/Providers/Transcription/Cloud/ChatGPTProvider.swift)
- [Sign-in and connection-test UI](VoiceInk/Features/ModelLibrary/Views/ChatGPT/ChatGPTConnectionView.swift)
- [Text enhancement routing](VoiceInk/Infrastructure/Providers/Enhancement/Chat/AIChatCompletionService.swift)
- [Protocol and HTTP tests](Tests/ChatGPTCoreTests)
- [macOS build workflow](.github/workflows/chatgpt-macos.yml)

## Current validation and remaining limits

Audio transcription has been reported working by the test user inside the native
app. A live text diagnostic using the app's own login returned HTTP 200 and a
complete SSE response. The latest build addresses the missing `Content-Type`
header and stream-completion formats observed during that investigation. Those
checks are not a guarantee that every account, model or future server version
will work.

The latest application build passed 27 automated protocol/HTTP tests, macOS client
type-checking, a full app build and signature verification. These tests use mocked
responses and do not require an OpenAI account. The app is ad-hoc signed, not
Apple-notarized. See [installation and build instructions](CHATGPT-BUILD.md).

The transcription and Codex backend routes are not a documented, stable public
API for third-party dictation applications. A successful request does not establish
unlimited usage, guaranteed included audio minutes, a per-minute price or permanent
availability. Access and limits depend on the account and OpenAI's service. This
implementation is experimental and should be reviewed before upstream adoption.

The app does not currently provide a complete per-app token-usage ledger or a
reliable conversion from requests into remaining subscription allowance.

## Data handling and side-by-side testing

Audio and enhancement inputs are sent to OpenAI. If enabled for a mode, selected
text, clipboard content or captured window text can also be included in enhancement
requests. This cloud path is not offline processing.

The test app is named **VoiceInk ChatGPT** and uses a separate bundle identifier,
preferences, credential namespace and application data directories. It does not
replace the installed VoiceInk app or open its history database. Settings can be
copied with backup export/import; history and account connections are not migrated.
FluidAudio's model cache remains managed by that library and may be shared.

## Notes for an upstream integration

The provider, native client and protocol parser are the main reusable components.
The separate app identity is for safe side-by-side testing and does not need to be
adopted by upstream. An upstream version could integrate the provider into the
existing VoiceInk identity and retain users' existing settings in place.

Before wider distribution, review OAuth client eligibility and service terms,
backend compatibility, failure handling, account/model availability, usage-limit
messaging and end-to-end tests on the supported macOS versions. This work does not
establish an officially supported OpenAI integration.

Implementation changes are collected in [pull request #1](https://github.com/megaschatzi/VoiceInk-ChatGPT/pull/1).
This is a pull request within the development repository, not a pull request
submitted to Beingpax/VoiceInk. The original project's GPL-3.0 license applies.

## Relationship to upstream and updates

This repository was created as an independent copy because the initial test work
needed a private repository. It retains the upstream Git history but is not
currently registered in GitHub's fork network, so GitHub does not show a
“forked from” label. The original project is explicitly credited above and in the
README. Making the repository public does not automatically add that label or
submit the changes to upstream.

Upstream source changes can be fetched from `Beingpax/VoiceInk`, merged into the
ChatGPT development branch, reviewed for conflicts and validated with the protocol
tests and macOS build workflow. They are not merged automatically.

The separate test app does not use the original VoiceInk automatic updater. After
an upstream merge or a change to this integration, a new test build must be
produced and installed by replacing **VoiceInk ChatGPT.app**. Keeping the same
ChatGPT app identity preserves its existing settings and local data. The original
VoiceInk installation continues to use its own update mechanism.
