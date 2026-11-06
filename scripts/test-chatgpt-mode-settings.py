#!/usr/bin/env python3
"""Execute the real ModeConfig Codable implementation without app dependencies.
The manager below that value type is excluded; no serialization code is copied.
Requires Swift on macOS, as does the app.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
mode_source = (root / 'VoiceInk/Features/Modes/State/ModeConfig.swift').read_text()
value_types, separator, _ = mode_source.partition('class ModeManager: ObservableObject')
assert separator, 'Update test boundary if the mode manager moves.'
files = ['VoiceInk/Infrastructure/Providers/ChatGPT/ChatGPTProtocol.swift',
         'VoiceInk/Features/Modes/Models/ModeIcon.swift',
         'VoiceInk/Features/Settings/FinishAndSendSettings.swift',
         'VoiceInk/Features/Modes/Models/ModeTriggerModels.swift']
source = '\n'.join((root / name).read_text() for name in files) + '\n' + value_types
source += r'''
let originalID = UUID()
let legacy: [String: Any] = ["id": originalID.uuidString, "name": "Email",
    "isAIEnhancementEnabled": true, "selectedAIProvider": "ChatGPT", "selectedAIModel": "gpt-6.1-sol"]
let decoder = JSONDecoder()
let oldMode = try decoder.decode(ModeConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
precondition(oldMode.chatGPTReasoningEffort == .low, "Old modes must retain Low")
for effort in ChatGPTReasoningEffort.allCases {
    var mode = oldMode
    mode.chatGPTReasoningEffort = effort
    let backup = try JSONEncoder().encode(["modeConfigs": [mode]])
    let restored = try decoder.decode([String: [ModeConfig]].self, from: backup)["modeConfigs"]![0]
    precondition(restored.chatGPTReasoningEffort == effort, "Effort must survive backup round trip")
    precondition(restored.id == originalID && restored.name == "Email")
    precondition(restored.selectedAIModel == "gpt-6.1-sol")
}
var future = legacy
future["chatGPTReasoningEffort"] = "unknown-future-level"
let restored = try decoder.decode(ModeConfig.self, from: JSONSerialization.data(withJSONObject: future))
precondition(restored.chatGPTReasoningEffort == .low, "Unknown effort must not break existing modes")
print("Mode settings: legacy defaults, six backup round trips and unknown-level migration passed.")
'''
with tempfile.TemporaryDirectory(prefix='voiceink-mode-test-') as folder:
    file = Path(folder) / 'main.swift'
    file.write_text(source)
    subprocess.run(['swift', str(file)], check=True, cwd=root)
