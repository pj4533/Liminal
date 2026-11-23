"""Offline mix measurements for Liminal Lo-Fi captures (NumPy, SciPy, Matplotlib and ffmpeg only).

See docs/plans/mpc-chopping.md section 9 for the measurement and criterion definitions.
"""


def strict_failures(results):
    return [row['id'] for row in results if row['level'] == 'fail' and (
        row['status'] == 'fail' or (row['status'] == 'skipped'
        and row.get('reason') not in ('no dialogue', 'no footage')
        and 'not applicable' not in str(row.get('reason', ''))))]
