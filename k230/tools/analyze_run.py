"""Desktop: python analyze_run.py <copied session directory or analysis folder>.

Exports inspectable track CSV and summary; tolerates incomplete final JSON lines.
It replays stored measurements, not missing images or ground truth trajectories.
"""
import argparse
import csv
import json
import pathlib


def analyze(path):
    root=pathlib.Path(path)
    if (root/'analysis').is_dir(): root=root/'analysis'
    files=sorted(root.glob('frames_*.jsonl'))
    if not files:
        raise ValueError('No analysis/frames_*.jsonl files found')
    output=root/'report'
    output.mkdir(exist_ok=True)
    summary={'frame_records':0,'invalid_lines':[],'count_events':[],
             'controls':[],'uncertain_events':[],'errors':[],'performance':[],
             'saved_images':0,'rate_limited_images':0,'end_record_seen':False,
             'sequence_uncertain_seen':False}
    event_keys=set()
    def add_events(row):
        for event in row.get('events',[]):
            key=(row['frame'],event.get('track'),event['label'])
            if key not in event_keys:
                event_keys.add(key)
                summary['count_events'].append({'frame':row['frame'],'ticks_ms':row['ticks_ms'],**event})
    with (output/'tracks.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.writer(f)
        writer.writerow(('frame','ticks_ms','tracker_ms','epoch','id','color','state',
                         'box_x','box_y','box_w','box_h','vx_px_per_ms','observed','counted','blocked','image'))
        for file in files:
            with file.open(encoding='utf-8',errors='replace') as stream:
                for number,line in enumerate(stream,1):
                    try:
                        if '\ufffd' in line:
                            raise ValueError('Damaged UTF-8')
                        row=json.loads(line)
                    except (ValueError,UnicodeError):
                        summary['invalid_lines'].append({'file':file.name,'line':number})
                        continue
                    kind=row.get('kind')
                    if kind=='end': summary['end_record_seen']=True
                    elif kind=='error': summary['errors'].append(row)
                    elif kind=='control': summary['controls'].append(row)
                    elif kind=='perf': summary['performance'].append(row)
                    elif kind=='count_events': add_events(row)
                    elif kind=='frame':
                        summary['frame_records']+=1
                        image=row.get('image',{})
                        if image.get('saved'): summary['saved_images']+=1
                        if image.get('reason')=='rate_limited': summary['rate_limited_images']+=1
                        add_events(row)
                        tracking=row.get('tracking') or {}
                        summary['sequence_uncertain_seen'] |= bool(tracking.get('sequence_uncertain'))
                        for note in tracking.get('notes',[]):
                            if note['kind'] in ('uncertain_crossing','order_ambiguous','association_ambiguous','common_jump','lost'):
                                summary['uncertain_events'].append({'frame':row['frame'],**note})
                        for track in tracking.get('tracks',[]):
                            writer.writerow((row['frame'],row['ticks_ms'],tracking.get('time_ms'),
                                tracking.get('epoch'),track['id'],track['color'],track['state'],
                                *track['box'],track['vx'],track['observed'],track['counted'],track['blocked'],
                                image.get('file','')))
    with (output/'summary.json').open('w',encoding='utf-8') as f:
        json.dump(summary,f,ensure_ascii=False,indent=2)
    print('Frames:',summary['frame_records'],'count events:',len(summary['count_events']),
          'images:',summary['saved_images'],'invalid lines:',len(summary['invalid_lines']))
    print('Clean end record:',summary['end_record_seen'],'errors:',len(summary['errors']))
    print('Report:',output.resolve())
    return summary


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('session')
    args=parser.parse_args()
    analyze(args.session)
