//
//  RecordControls.swift
//  Liminal
//
//  The Record button under Play/Stop, shared by the macOS panel and the visionOS control window
//  (docs/recording.md). It records the picture and the mix, then saves the movie to Photos.
//

import SwiftUI

struct RecordControls: View {
    @ObservedObject var audio: GenerativeEngine
    @ObservedObject private var recorder = RecordingController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                recorder.toggle(audio: audio)
            } label: {
                Label(title, systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
            }
            .controlSize(.large)
            .disabled(recorder.phase == .finishing || (!recorder.isRecording && !audio.isPlaybackReady))
            .accessibilityIdentifier("record")

            status
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch recorder.phase {
        case .recording: return "Stop Recording"
        case .finishing: return "Saving…"
        default: return "Record"
        }
    }

    @ViewBuilder private var status: some View {
        switch recorder.phase {
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(since))
                Label(String(format: "Recording %d:%02d", elapsed / 60, elapsed % 60), systemImage: "circle.fill")
                    .foregroundStyle(.red)
            }
        case .finishing:
            Text("Finishing the movie…")
        case .saved(let message):
            Text(message)
        case .failed(let message):
            Text("Recording failed: \(message)").foregroundStyle(.yellow)
        case .idle:
            Text("Records the picture and the music, then saves the movie to Photos.")
        }
    }
}
