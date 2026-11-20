"""Linux source-contract checks; do not substitute these for native audio tests."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def source(name):
    return (ROOT / name).read_text()


class ControllerAudioSourceContract(unittest.TestCase):
    def test_expensive_wet_preparation_requires_explicit_native_qualification(self):
        bus = source('Liminal/Audio/Lofi/LofiBus.swift')
        self.assertIn('nonisolated static let isolatedPreparationQualified = false', bus)
        renderer = source('Liminal/Audio/Lofi/LofiRenderer.swift')
        self.assertIn('prepareIsolatedWet: Bool = false', renderer)
        self.assertIn('if prepareIsolatedWet {', renderer)
        playback = source('Liminal/Audio/Lofi/LofiPlayback.swift')
        self.assertIn('prepareIsolatedWet: LofiBus.isolatedPreparationQualified', playback)

    def test_manual_switch_does_not_mutate_transport_or_generation(self):
        bus = source('Liminal/Audio/Lofi/LofiBus.swift')
        mode = bus.split('func setAutomatic(')[1].split('func reset(')[0]
        for forbidden in ['.stop(', '.play(', '.scheduleBuffer(', 'transportRevision', 'queuedFrames', 'seed =']:
            self.assertNotIn(forbidden, mode)
        engine = source('Liminal/Audio/GenerativeEngine.swift')
        mode = engine.split('func controllerSetAutomatic(')[1].split('func controllerReset(')[0]
        self.assertNotIn('.setActive(', mode)
        self.assertNotIn('.silence(', mode)
        self.assertNotIn('.stop(', mode)

    def test_source_isolation_excludes_sample_grain_anchors(self):
        fx = source('Liminal/Audio/Lofi/LofiEffects.swift')
        self.assertIn('includeLead && $0.part == .lead', fx)
        self.assertIn('includeMids && $0.part == .texture', fx)
        renderer = source('Liminal/Audio/Lofi/LofiRenderer.swift')
        self.assertIn('leadPickup: true, includeMids: false', renderer)
        self.assertIn('leadPickup: false, includeLead: false', renderer)
        self.assertIn('index < isolatedCarry.count ? isolatedCarry[index] : nil', renderer)

    def test_duck_faders_have_no_controller_writer(self):
        text = source('Liminal/Controller/ControllerCoordinator.swift') + source('Liminal/Controller/ControllerChannelStrip.swift')
        for name in ['dryFader', 'textureFader', 'wetFader']:
            self.assertNotIn(name, text)

    def test_manual_readiness_requires_assets_and_source_isolation(self):
        coordinator = source('Liminal/Controller/ControllerCoordinator.swift')
        self.assertIn('"performance_audio": .bool(manualReady || manualPadsReady)', coordinator)
        self.assertIn('"manual_notes": .bool(manualReady)', coordinator)
        self.assertIn('"manual_pads": .bool(manualPadsReady)', coordinator)
        self.assertIn('engine?.controllerModeReady(id) == true && instrument?.ready == true', coordinator)
        engine = source('Liminal/Audio/GenerativeEngine.swift')
        self.assertIn('[ControllerChannel.lofiSpace, .ambientSpace, .film]', engine)

    def test_onset_hot_path_never_builds_or_renders_instruments(self):
        bank = source('Liminal/Controller/ControllerVoiceBank.swift')
        onset = bank.split('func noteOn(')[1].split('private var pending:')[0]
        for forbidden in ['LofiBassVoice.render', 'LofiPadVoice.render', 'addInstrument(', 'AVAudioPCMBuffer(', 'ControllerAmbientVoice(', 'addInput(']:
            self.assertNotIn(forbidden, onset)
        worker = source('Liminal/Controller/ControllerLofiCache.swift')
        for required in ['LofiBassVoice.render', 'LofiPadVoice.render', 'LofiRenderer.addInstrument', 'try Task.checkCancellation()', 'ControllerPCMReservation']:
            self.assertIn(required, worker)

    def test_lifecycle_releases_captured_tokens_and_preserves_disconnect_mix(self):
        coordinator = source('Liminal/Controller/ControllerCoordinator.swift')
        disconnect = coordinator.split('private func disconnect(')[1].split('private func release(')[0]
        self.assertIn('release(onsets.releaseAll(session: session))', disconnect)
        self.assertNotIn('controllerReset', disconnect)
        self.assertNotIn('controllerSetAutomatic', disconnect)
        self.assertIn('if automatic { release(onsets.releaseAll(channel: channel), over: 0.03) }', coordinator)
        self.assertIn('engine.controllerVoices.pressure(onset.voiceToken', coordinator)
        self.assertIn('engine?.controllerVoices.release(onset.voiceToken', coordinator)

    def test_actual_audible_score_and_source_owned_manual_wet(self):
        playback = source('Liminal/Audio/Lofi/LofiPlayback.swift')
        descriptor = playback.split('var controllerInstruments:')[1].split('private struct PlayingPhrase')[0]
        self.assertIn('$0.music.score', descriptor)
        self.assertNotIn('$0.request', descriptor)
        bus = source('Liminal/Audio/Lofi/LofiBus.swift')
        wet = bus.split('var manualWetInputs:')[1].split('private func sourceIndex')[0]
        self.assertIn('isolatedStrips[0].manualInput', wet)
        self.assertNotIn('legacyWet', wet)


if __name__ == '__main__':
    unittest.main()
