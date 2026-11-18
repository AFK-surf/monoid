"""Strict outcome checker; preserves failures instead of relaxing thresholds."""
import json, math, pathlib, sys

def percentile(rows, p):
    values=sorted(rows)
    return values[math.ceil(len(values)*p)-1] if values else None

def check(path):
    data=json.loads(path.read_text()); errors=[]; scenario=data['scenario']
    def require(condition, reason):
        if not condition: errors.append(reason)
    samples=data['samples']; fault=data['fault_ms']; quic=data['quic']
    require(data.get('verified')==[35,35*65536], 'original-stream data verification missing')
    mappings={(r['node'],r['circuit']):r['path'] for r in data['routes']}
    selected=[{**q,'path':mappings.get((q['node'],q['circuit']))} for q in quic if q['selected']]
    require(bool(selected), 'no actual QUIC selection observations')
    require(all(q['path'] is not None for q in selected), 'selected circuit missing path mapping')
    expected={0:[0,3],3:[3,0]} if scenario=='flap' else {0:[0,1,2,3],3:[3,2,1,0]}
    events=[{**q,'path':mappings.get((q['node'],q['circuit']))} for q in data.get('events',[])]
    require({q['node'] for q in events}=={0,3}, 'continuous path events missing at an endpoint')
    if scenario=='chain':
        require(data.get('connected_ms') is not None and data['connected_ms']<=5000, 'cold connect >5000 ms or absent')
        warm=[s['ms'] for s in samples if s['sequence']>=15]
        require({q['node'] for q in selected if q['sequence']>=15}=={0,3}, 'warm chain endpoint observations missing')
        require(all(q['path']==expected[q['node']] for q in selected if q['sequence']>=15), 'warm chain actual selected path mismatch')
    elif scenario=='soft':
        require(samples[4]['ms']<=2540, 'first impaired request >2540 ms')
        for node in (0,3):
            observations=[q for q in events if q['node']==node and q['at_ms']>=fault]
            first=next((q for q in observations if q['path']==expected[node]),None)
            require(first is not None and first['at_ms']-fault<=6000, f'node {node} convergence >6000 ms or absent')
            require(all(q['path']==expected[node] for q in observations if q['at_ms']>=fault+6000), f'node {node} selected direct after convergence budget')
        # Sample end time minus request duration excludes requests crossing the budget.
        warm=[s['ms'] for s in samples if s['at_ms']-s['ms']>=fault+6000]
        require(all(q['path']==expected[q['node']] for q in selected if q['at_ms']>=fault+6000), 'selected snapshots contradict convergence')
    else:
        require(all(q['path']==expected[q['node']] for q in selected), 'flap switched actual selected path')
        require(all(q['path']==expected[q['node']] for q in events), 'flap path event switched or has unknown circuit')
        warm=[s['ms'] for s in samples if s['sequence']>=15]
    require(len(warm)>=10, 'fewer than 10 warm observations')
    require(bool(warm) and percentile(warm,.95)<=200, 'warm p95 >200 ms or absent')
    summary={'scenario':scenario,'cold_connect_ms':data.get('connected_ms'),'warm_n':len(warm),'warm_p50_ms':percentile(warm,.5),'warm_p95_ms':percentile(warm,.95),'errors':errors}
    print(json.dumps(summary,indent=2));return not errors

if __name__=='__main__':
    sys.exit(0 if check(pathlib.Path(sys.argv[1])) else 1)
