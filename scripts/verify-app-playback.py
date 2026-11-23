#!/usr/bin/env python3
"""Automated playback evidence only; does not substitute for human visual/listening review."""
import json
from pathlib import Path
import re
import sys


NUMBER = r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'
HOOK = re.compile(
    rf'Lo-Fi dialogue hook cue=(?P<cue>\d+) loop=(?P<loop>\d+) interest=(?P<interest>{NUMBER}) '
    r'line="(?P<line>.*?)".*?\btemplate=(?P<template>\d+) S="(?P<signature>.*?)" '
    r'R="(?P<response>.*?)" T="(?P<third>.*?)" bars=(?P<bars>b\d+:.+?)(?: chopRepeat=|$)'
)
PIECE = re.compile(
    rf'📼 piece #(?P<piece>\d+) slot=(?P<slot>\d+) .*?\bid=(?P<id>\S+) title=".*?" '
    rf'segment=(?P<segment>{NUMBER})s .*?\bsound=(?P<sound>true|false) \(wanted (?:true|false), '
    r'audio=(?P<audio>true|false)\)'
)
SALIENT = re.compile(
    rf'\bsalient-pick id=(?P<id>\S+) line=(?P<start>{NUMBER})\.\.\.(?P<end>{NUMBER}) '
    rf'interest=(?P<interest>{NUMBER}) peakWord=(?P<peakWord>.*?) peakWeight=(?P<peakWeight>{NUMBER})(?:\s|$)'
)
FAULTS = {
    'runtime': re.compile(r'fatal error|audio engine failed|render error', re.I),
    'archiveDecode': re.compile(r'no (?:dialogue|sound): (?:native )?decode failed', re.I),
    'archivePlayback': re.compile(
        r'📼 (?:footage unavailable|piece dropped|invalid clip|.*LiminalVideoFile .*unusable)'
        r'|archive cue format mismatch|📼🔊 sound started \d+(?:\.\d+)?s late', re.I
    ),
    'lateChops': re.compile(r'Lo-Fi dialogue dropped (?P<count>[1-9]\d*) late chops?', re.I),
}


def evidence(text):
    hooks, sound_pieces, picks, matched_picks, errors, faults = [], [], [], [], [], []
    pending_pick = None
    for line in text.splitlines():
        for category, pattern in FAULTS.items():
            match = pattern.search(line)
            if match:
                faults.append(dict(kind=category, log=line, **match.groupdict()))
                if not errors or errors[-1] != line:
                    errors.append(line)
        if match := HOOK.search(line):
            hooks.append(match.groupdict())
        if match := SALIENT.search(line):
            pending_pick = match.groupdict()
            picks.append(pending_pick)
        if match := PIECE.search(line):
            piece = match.groupdict()
            if piece['sound'] == 'true' and piece['audio'] == 'true':
                sound_pieces.append(piece)
                if pending_pick and pending_pick['id'] == piece['id']:
                    matched_picks.append(dict(pick=pending_pick, piece=piece))
            # prepare() logs at most one pick immediately before its piece. Do not pair a
            # stale pick with a later visit of the same clip.
            pending_pick = None
    return dict(hook=bool(hooks), footage=bool(sound_pieces), salientPick=bool(matched_picks),
                hooks=hooks, soundPieces=sound_pieces, salientPicks=picks,
                matchedSalientPicks=matched_picks, errors=errors, faults=faults)


if __name__ == '__main__':
    results = [evidence(Path(p).read_text(errors='replace')) for p in sys.argv[1:]]
    combined = {key: any(run[key] for run in results) for key in ('hook', 'footage', 'salientPick')}
    combined.update({key: [entry for run in results for entry in run[key]]
                     for key in ('hooks', 'soundPieces', 'salientPicks', 'matchedSalientPicks', 'errors', 'faults')})
    print(json.dumps(dict(automatic=combined, humanVisual='unverified', humanListening='unverified'), indent=2))
    raise SystemExit(0 if combined['hook'] and combined['footage'] and combined['salientPick'] and not combined['errors'] else 1)
