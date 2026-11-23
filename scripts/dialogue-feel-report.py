#!/usr/bin/env python3
"""Summarize FEEL-METRIC JSON lines in Swift test logs or exported attachments."""
import argparse
import collections
import json
import pathlib
import statistics


def summarize(records):
    groups = collections.defaultdict(list)
    for row in records:
        groups[(row['film'], row['seed'])].append(row)
    pairs = [(a, b) for rows in groups.values()
             for a, b in zip(sorted(rows, key=lambda r: r['loop']), sorted(rows, key=lambda r: r['loop'])[1:])]
    result = {'loops': len(records), 'pairs': len(pairs), 'crossLinePairs': sum(a['line'] != b['line'] for a, b in pairs)}
    for move in ['reverse', 'rest', 'roll', 'stutter', 'quiet']:
        totals = collections.Counter(p for row in records for p in set(row['moves'][move]))
        earlier = sum(len(set(a['moves'][move])) for a, _ in pairs)
        repeated = sum(len(set(a['moves'][move]) & set(b['moves'][move])) for a, b in pairs)
        # Leave-one-seed-out position predictor: predict occupied positions using the other seeds'
        # majority at each position; balanced accuracy avoids calling sparse moves predictable by absence.
        tp = tn = pos = neg = 0
        for row in records:
            train = [r for r in records if r['film'] == row['film'] and r['seed'] != row['seed']]
            counts = collections.Counter(p for r in train for p in set(r['moves'][move]))
            actual = set(row['moves'][move])
            for p in range(256):
                prediction = counts[p] * 2 >= len(train)
                if p in actual:
                    pos += 1
                    tp += prediction
                else:
                    neg += 1
                    tn += not prediction
        result[move] = {'count': sum(totals.values()), 'repeatGivenPrevious': repeated / max(1, earlier),
                        'peakPositionShare': max(totals.values(), default=0) / max(1, len(records)),
                        'positionPredictability': ((tp / pos if pos else 0) + (tn / neg if neg else 0)) / 2,
                        'positions': dict(sorted(totals.items()))}
    def jaccard(a, b):
        a, b = set(a), set(b)
        return len(a & b) / max(1, len(a | b))
    result['consecutiveGridSimilarity'] = statistics.mean(jaccard(a['grid'], b['grid']) for a, b in pairs) if pairs else 0
    result['hookRecurrence'] = statistics.mean(r['hookRecurrence'] for r in records) if records else 0
    # Next-move prediction from preceding move class (leave-one-seed-out majority transition).
    sequences = []
    for row in records:
        seq = sorted((p, move) for move in ['reverse', 'roll', 'stutter'] for p in row['moves'][move])
        sequences.append((row, [m for _, m in seq]))
    correct = total = 0
    for row, seq in sequences:
        transitions = collections.defaultdict(collections.Counter)
        for other, train in sequences:
            if other['seed'] != row['seed']:
                for a, b in zip(train, train[1:]):
                    transitions[a][b] += 1
        for a, b in zip(seq, seq[1:]):
            if transitions[a]:
                guess = sorted(transitions[a], key=lambda m: (-transitions[a][m], m))[0]
                correct += guess == b
                total += 1
    result['nextMovePredictability'] = correct / max(1, total)
    result['nextMoveTransitions'] = total
    return result


def read_records(path):
    records = {}
    for file in sorted(path.rglob('*')) if path.is_dir() else [path]:
        if not file.is_file():
            continue
        for line in file.read_text(errors='replace').splitlines():
            if 'FEEL-METRIC {' not in line:
                continue
            row, _ = json.JSONDecoder().raw_decode(line.split('FEEL-METRIC ', 1)[1])
            records[(row['film'], row['seed'], row['loop'])] = row
    return list(records.values())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=pathlib.Path)
    args = parser.parse_args()
    records = read_records(args.input)
    if not records:
        parser.error('no FEEL-METRIC records found')
    print(json.dumps(summarize(records), indent=2, sort_keys=True))
