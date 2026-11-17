#!/usr/bin/env python3
"""Battery drain per suspend from the suspend-drain log of unit 20.

Usage: drain_report.py [suspend-drain.jsonl] [--since EPOCH] [--json]
Pairs each "suspend" line with the next "resume" line of the same boot and prints,
per suspend, the hours suspended, the loss in %/h and mV/h, and the current the gauge's
time-to-empty implies right after resume (capacity x 30 mAh / time_to_empty).
Suspends shorter than 10 min, with the charger in or a missing gauge are listed but
left out of the per-mode figures. The gauge's capacity is a whole percent (and its
charge_counter is derived from it, 30 000 uAh per percent), so a 45 min suspend at
~5 %/h is measured to about +-1 %: compare modes over several suspends.
"""
import json
import sys

LOG = '/userdata/system/logs/suspend-drain.jsonl'
MIN_SECONDS = 600


def pairs(lines):
    pending = None
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('ev') == 'suspend':
            pending = event
        elif event.get('ev') == 'resume' and pending and pending.get('boot') == event.get('boot'):
            yield pending, event
            pending = None


def describe(before, after):
    seconds = after['t'] - before['t']
    row = {'start': before['t'], 'hours': round(seconds / 3600, 3), 'mode': before.get('mode', 'stock'),
           'cap_before': before.get('cap'), 'cap_after': after.get('cap'),
           'mv_before': before.get('uv', 0) // 1000, 'mv_after': after.get('uv', 0) // 1000,
           'tte_after_min': (after.get('tte') or 0) // 60, 'status': before.get('status')}
    if after.get('tte') and after.get('cap') is not None:
        row['ma_from_tte'] = round(after['cap'] * 30 * 3600 / after['tte'])
    usable = (seconds >= MIN_SECONDS and before.get('status') == 'Discharging'
              and after.get('status') == 'Discharging' and None not in (before.get('cap'), after.get('cap')))
    if seconds > 0:
        row['pct_per_h'] = round((before['cap'] - after['cap']) / (seconds / 3600), 2) if usable else None
        row['mv_per_h'] = round((row['mv_before'] - row['mv_after']) / (seconds / 3600), 1) if usable else None
    row['usable'] = usable
    return row


def main(argv):
    args = argv[1:]
    since = 0
    if '--since' in args:
        since = int(args[args.index('--since') + 1])
        del args[args.index('--since'):args.index('--since') + 2]
    path = next((a for a in args if not a.startswith('--')), LOG)
    with open(path) as source:
        rows = [describe(b, a) for b, a in pairs(source) if b['t'] >= since]
    modes = {}
    for row in rows:
        if row['usable']:
            m = modes.setdefault(row['mode'], {'suspends': 0, 'hours': 0.0, 'pct': 0, 'mv': 0})
            m['suspends'] += 1
            m['hours'] += row['hours']
            m['pct'] += row['cap_before'] - row['cap_after']
            m['mv'] += row['mv_before'] - row['mv_after']
    summary = {mode: {'suspends': m['suspends'], 'hours': round(m['hours'], 2),
                      'pct_per_h': round(m['pct'] / m['hours'], 2), 'mv_per_h': round(m['mv'] / m['hours'], 1),
                      'pct_lost': m['pct']} for mode, m in modes.items() if m['hours']}
    if '--json' in argv:
        print(json.dumps({'suspends': rows, 'modes': summary}, indent=1))
        return 0
    for row in rows:
        print('{start} {mode:10} {hours:6.2f} h  {cap_before}->{cap_after} %  {mv_before}->{mv_after} mV  '
              '{pct_per_h} %/h  {mv_per_h} mV/h  tte_after={tte_after_min} min (~{ma} mA){note}'.format(
                  note='' if row['usable'] else '  (not counted)', ma=row.get('ma_from_tte'), **row))
    for mode, m in summary.items():
        print('mode {}: {} suspends, {} h, {} %/h, {} mV/h'.format(mode, m['suspends'], m['hours'],
                                                                  m['pct_per_h'], m['mv_per_h']))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
