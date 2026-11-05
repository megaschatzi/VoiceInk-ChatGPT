# VoiceInk ChatGPT test app

For an overview of audio transcription, text enhancement and reusable components,
see [Native ChatGPT integration](CHATGPT-INTEGRATION.md).

This development copy adds an experimental direct ChatGPT/Codex OAuth
connection. It needs neither an API key nor an installed Codex CLI. It uses a
browser device-code sign-in, stores credentials in a separate non-syncing macOS
Keychain item, and refreshes tokens when needed. The native OAuth protocol follows
OpenAI's public Codex client implementation. This is separate from the general
Sign in with ChatGPT token-sharing flow, which currently does not support audio.

## Install a test build

1. Open this repository's **Actions** tab and the latest successful **VoiceInk
   ChatGPT macOS** run for `feature/chatgpt-native`.
2. Download **VoiceInk-ChatGPT-macOS** under Artifacts. Unzip the artifact and then
   `VoiceInk-ChatGPT-macOS.zip`. Move **VoiceInk ChatGPT.app** into Applications.
3. The build is ad-hoc signed, not Apple-notarized. macOS may require explicit
   approval under System Settings → Privacy & Security. Do not disable Gatekeeper.
4. Grant microphone and accessibility permissions to the new app. Run one dictation
   app at a time to avoid duplicate global keyboard shortcuts.

The app has its own bundle identifier, preferences, credential namespace, SwiftData
stores and recordings directory. It does not replace VoiceInk or open its stores.
FluidAudio's model cache remains managed by that library and may be shared.

## Keep existing settings

In the original VoiceInk, use **Settings → Backup → Export Settings**. In VoiceInk
ChatGPT, use **Settings → Backup → Import Settings** and choose the categories to
copy. The existing importer supports modes, prompts, shortcuts and dictionary data.
History is not migrated. Account connections and macOS permissions are separate.
Keep the original app installed until you have verified your imported settings.

## Connect and test

1. Open **Model Catalog → Cloud → ChatGPT**.
2. Choose **Sign in with ChatGPT**. Enter the displayed one-time code on OpenAI's
   sign-in page. Device code authentication must be enabled for your account.
3. Use **Test text connection** and **Test audio file…** to verify the new grant.
   Tests send their text/audio to OpenAI and use whatever allowance the account permits.
4. Choose **Use ChatGPT for dictation** for the global transcription model, or
   select **ChatGPT Dictation** in the relevant mode. For text cleanup, enable
   **AI Enhancement** in that mode and choose **ChatGPT** plus the desired model.

ChatGPT's dictation backend chooses the speech model; this app does not advertise
a specific Whisper/Transcribe model. The text model is independent and configurable.
Model presets do not guarantee entitlement for every account.

## Limits

The audio request uses `https://chatgpt.com/backend-api/transcribe`, which has been reported working
inside the native test app after device-code sign-in. A live text diagnostic using
the app login also returned a complete SSE response; account-specific app testing
is still necessary. This internal endpoint has no
published compatibility guarantee or confirmed included minutes/pricing for this
integration. Text uses the Codex Responses route. Usage and access failures are
reported without switching accounts, providers or billing methods. A 401 is retried
once after token refresh; a 403 or 429 is not retried automatically.

No user login, tokens, recordings or settings are needed in GitHub Actions.

## Build locally

Requires Xcode, CMake and macOS 15 or later:

```sh
swift test
bash scripts/build-whisper-macos.sh
make local LOCAL_CODESIGN_IDENTITY=-
```

The app is copied to `~/Downloads/VoiceInk ChatGPT.app`.
