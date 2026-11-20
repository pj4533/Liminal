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

    def test_manual_audio_is_truthfully_unavailable(self):
        coordinator = source('Liminal/Controller/ControllerCoordinator.swift')
        self.assertIn('"performance_audio": .bool(false)', coordinator)
        self.assertIn('"manual_notes": .bool(false)', coordinator)
        engine = source('Liminal/Audio/GenerativeEngine.swift')
        self.assertIn('[ControllerChannel.chops, .lofiSpace, .ambientSpace, .film]', engine)


if __name__ == '__main__':
    unittest.main()
