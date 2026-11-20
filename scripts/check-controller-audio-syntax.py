#!/usr/bin/env python3
"""Optional tree-sitter smoke check, NOT Swift type checking or a native build.

Requires tree-sitter and tree-sitter-swift. The Linux grammar cannot parse Swift's
conditional member declarations or existing nonisolated(unsafe) local bindings,
so directive lines and that modifier are removed in memory only. Both conditional
branch bodies are retained. Native Xcode builds remain required.
"""
from pathlib import Path
from tree_sitter import Language, Parser
import tree_sitter_swift

root = Path(__file__).resolve().parents[1]
paths = [
    'Liminal/Audio/GenerativeEngine.swift',
    'Liminal/Audio/ArchiveVoice.swift',
    'Liminal/Audio/Lofi/Dialogue/DialogueCueCoordinator.swift',
    'LiminalTests/ControllerDialogueTests.swift',
    'LiminalTests/ControllerDrumTests.swift',
    'Liminal/Audio/Layers/MusicLayer.swift',
    'Liminal/Audio/Lofi/LofiBus.swift',
    'Liminal/Audio/Lofi/LofiEffects.swift',
    'Liminal/Audio/Lofi/LofiPlayback.swift',
    'Liminal/Audio/Lofi/LofiRenderer.swift',
    'Liminal/Audio/MixBus.swift',
    'Liminal/Controller/ControllerCoordinator.swift',
    'Liminal/Controller/ControllerState.swift',
    'Liminal/Controller/ControllerChannelStrip.swift',
    'LiminalTests/ControllerAudioRoutingTests.swift',
]
paths += [str(path.relative_to(root)) for path in (root / 'Liminal/Controller').glob('*.swift')]
paths += [str(path.relative_to(root)) for path in (root / 'Liminal/Audio/Layers').glob('*.swift')]
paths += ['Liminal/Audio/MusicConductor.swift', 'LiminalTests/ControllerInstrumentTests.swift']
paths = sorted(set(paths))
parser = Parser(Language(tree_sitter_swift.language()))
failed = []
for path in paths:
    data = (root / path).read_text().replace('nonisolated(unsafe)', '')
    data = '\n'.join(line for line in data.splitlines()
                     if not line.strip().startswith(('#if', '#else', '#endif')))
    if parser.parse(data.encode()).root_node.has_error:
        failed.append(path)
# The unchanged full footage-service body has an existing grammar error in its async
# optional-binding condition. Check the changed call fragment separately, without
# claiming the full file was parsed or type checked.
footage = (root / 'Liminal/Archive/ArchiveFootageService.swift').read_text()
fragment = footage[footage.index('_ = await director.run('):footage.index('manualPost: { sink.post(.archiveControllerBank($0)) })') + len('manualPost: { sink.post(.archiveControllerBank($0)) })')]
if parser.parse(('func check() async { ' + fragment + ' }').encode()).root_node.has_error:
    failed.append('ArchiveFootageService changed call fragment')
print(f'Normalized Swift syntax: {len(paths) + 1 - len(failed)} passed (including changed footage call fragment), {len(failed)} failed')
for path in failed:
    print(path)
raise SystemExit(bool(failed))
