## Model and reasoning settings per mode

Under **Modes → Edit → AI Enhancement**, select **ChatGPT** and choose both the text model and its reasoning level. The choice is saved per mode and included in settings backups. Existing modes keep **Low**.

- Current text models: GPT-6 Luna, GPT-6.1 Terra, GPT-6.1 Sol, GPT-6 Sol and GPT-6 Astra.
- Earlier models: GPT-5.6 Luna, Terra and Sol, with custom model IDs still available.
- Reasoning levels: None, Low, Medium, High, Extra high and Maximum where supported by the selected model. Sol 6.1 and Astra do not offer None. Custom IDs expose the common Low/Medium/High settings; access is still checked by the server.
- Expand **Model and language guidance** for practical starting points in German, English, French, Spanish, Italian, Portuguese and other/mixed languages. These are suggestions, not measured per-language quality rankings.
- German and English UI text is included. The transcription language and audio model are independent of the enhancement model and reasoning level.
- Medium and higher text requests allow at least 120 seconds before timeout. More reasoning may take longer and consume more allowance; it does not guarantee a better edit.

## Download and update

Download **VoiceInk-ChatGPT-macOS.zip** from the assets below. No GitHub account is required. Unzip it, quit the running test app, and replace **VoiceInk ChatGPT.app** in Applications. The existing ChatGPT app identity, settings and data are retained. The original VoiceInk app remains separate.

The build is ad-hoc signed, not Apple-notarized. macOS may require approval in **System Settings → Privacy & Security**. Do not disable Gatekeeper.

## Experimental ChatGPT connection

Native ChatGPT sign-in supports both audio transcription and optional text enhancement, without an API key or an installed CLI. The user has reported testing with ChatGPT Plus and Pro ($100/month). Model access is account-dependent. Included audio minutes, billing treatment and continued backend availability are not guaranteed. Audio and enabled enhancement context are sent to OpenAI.

The model catalog is a curated list, not a live account-entitlement query. The reasoning picker applies to the native **ChatGPT** provider. CLI commands retain their own model/effort settings.

[English integration overview](https://github.com/megaschatzi/VoiceInk-ChatGPT/blob/feature/chatgpt-native/CHATGPT-INTEGRATION.md)
