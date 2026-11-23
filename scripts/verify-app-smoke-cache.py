#!/usr/bin/env python3
"""Identify the disposable app playback inputs against the paired public audio corpus."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

PIN = 'aapb-cpb-aacip-514-n00zp3ws90'
PREFERRED = 'cpb-aacip-514-n00zp3ws90_The World of LSD.ia.mp4'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verified_reencode(identity, source_hash, playback_hash):
    source, playback = identity['source'], identity['transcoded']
    require(source['fileSHA256'] == source_hash and playback['fileSHA256'] == playback_hash,
            'The conversion evidence does not identify these source and playback bytes')
    require(source['video']['codec_name'] == 'vp9' and playback['video']['codec_name'] == 'h264',
            'Expected VP9 to H.264 video conversion')
    for key in ('audioPacketTimelineAndPayloadSHA256', 'decodedAudioPCM32SHA256', 'videoPacketTimelineSHA256'):
        require(re.fullmatch(r'[0-9a-f]{64}', source[key]) and source[key] == playback[key],
                f'Conversion evidence failed {key}')
    require(source['audio'] == playback['audio'] and source['containerDuration'] == playback['containerDuration'],
            'Audio metadata or container duration changed')
    for field in ('start_time', 'time_base', 'nb_frames', 'width', 'height'):
        require(source['video'][field] == playback['video'][field], f'Video {field} changed')
    require(abs(float(source['video']['duration']) - float(playback['video']['duration'])) < .001,
            'Video duration changed')


def verify(cache, dataset_path, identity_path):
    dataset = json.loads(dataset_path.read_text())
    clips = json.loads((cache / 'index.json').read_text())['clips']
    sources = {row['id']: row for row in dataset['films']}
    require(len(sources) == len(dataset['films']) == dataset['requested'] == dataset['prepared']
            and PIN in sources, 'Expected the complete paired dataset including the vetted pin')
    require(len(clips) == len(sources) and {c['id'] for c in clips} == sources.keys(),
            'App cache film IDs differ from the paired dataset')
    result = []
    used_identity = False
    for clip in clips:
        film = sources[clip['id']]
        filename = clip['fileName']
        require(filename and Path(filename).name == filename, 'Invalid indexed film path')
        file = cache / filename
        require(file.is_file() and not file.is_symlink() and file.stat().st_size == clip['bytes'],
                f'Missing or misindexed playback media for {film["id"]}')
        with file.open('rb') as stream:
            sha = hashlib.file_digest(stream, 'sha256').hexdigest()
        scope = 'paired Archive derivative'
        if film['id'] == PIN and sha != film['sha256'] and identity_path:
            verified_reencode(json.loads(identity_path.read_text()), film['sha256'], sha)
            used_identity = True
            scope = 'local H.264 video conversion with verified audio and video timing'
        else:
            require(sha == film['sha256'], f'Unaccounted playback derivative for {film["id"]}')
            if film['id'] == PIN:
                video = next((s for s in film['facts']['streams'] if s['codec_type'] == 'video'), {})
                require(film['archiveFile']['name'] == PREFERRED and video.get('codec_name') == 'h264',
                        'The original VP9 audio-probe fixture cannot certify app video playback. '
                        'Supply the qualified H.264 app cache and conversion identity, or use a paired corpus with the production pin.')
        result.append(dict(id=film['id'], archiveURL=film['url'], pairedSHA256=film['sha256'],
                           appSHA256=sha, scope=scope))
    require(not identity_path or used_identity, 'Supplied conversion evidence was not used')
    return dict(pairedDataset=str(dataset_path.resolve()), conversionIdentity=str(identity_path.resolve()) if identity_path else None,
                films=result)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cache', type=Path)
    parser.add_argument('dataset', type=Path)
    parser.add_argument('--identity', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.cache, args.dataset, args.identity), indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(f'App cache verification failed: {error}')
