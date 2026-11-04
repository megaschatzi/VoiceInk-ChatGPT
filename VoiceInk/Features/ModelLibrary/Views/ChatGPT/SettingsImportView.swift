import SwiftUI

struct SettingsImportView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Keep your VoiceInk settings").font(.caption.bold())
            Text("In your original VoiceInk app, export a backup under Settings → Backup. Import that file under Settings → Backup in VoiceInk ChatGPT. You can select modes, prompts, shortcuts, and dictionary entries. Your original app and history remain unchanged. Account connections and macOS permissions need to be set up again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
