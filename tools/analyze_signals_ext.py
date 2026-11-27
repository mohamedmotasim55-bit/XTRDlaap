#!/usr/bin/env python3
"""Extended-horizon signal validation. Read-only. No trading, no tuning."""
import csv, sys, os, random, math, statistics
from collections import defaultdict, OrderedDict

HZ = ["10s","30s","60s","120s","300s"]
MIN_N_VERDICT = 200          # below this: no verdict (small sample)
BLOCK = 20                   # moving-block bootstrap block length (signals)
BOOT = 2000                  # bootstrap resamples
SEED = 20261127

def rd(p):
    with open(p, newline='', encoding='utf-8', errors='ignore') as f:
        return list(csv.DictReader(f))

def fnum(x):
    try:
        v=float(x); return v if math.isfinite(v) else None
    except: return None

def block_bootstrap_ci(vals, block=BLOCK, boot=BOOT, seed=SEED):
    vals=[v for v in vals if v is not None]
    n=len(vals)
    if n<10: return (None,None)
    a=list(vals)
    rng=random.Random(seed)
    nb=max(1, math.ceil(n/block))
    maxstart=max(1,n-block+1)
    means=[]
    for _ in range(boot):
        samp=[]
        for _ in range(nb):
            s=rng.randrange(0,maxstart)
            samp.extend(a[s:s+block])
        samp=samp[:n]
        means.append(sum(samp)/len(samp))
    means.sort()
    lo=means[int(0.025*(len(means)-1))]
    hi=means[int(0.975*(len(means)-1))]
    return (float(lo),float(hi))

def verdict(mean, lo, hi, n):
    if n < MIN_N_VERDICT: return "small sample — no verdict"
    if mean>0 and lo is not None and lo>0: return "Positive evidence"
    if mean<0 and hi is not None and hi<0: return "Negative evidence"
    return "Inconclusive"

def stats(vals):
    v=[x for x in vals if x is not None]
    if not v: return dict(n=0,mean=None,median=None,pos=0,pctpos=None,lo=None,hi=None)
    lo,hi=block_bootstrap_ci(v)
    return dict(n=len(v), mean=float(statistics.mean(v)), median=float(statistics.median(v)),
                pos=sum(1 for x in v if x>0), pctpos=100*sum(1 for x in v if x>0)/len(v),
                lo=lo, hi=hi)

def cluster(sig_rows, gap_s=60):
    """Group temporally close same-direction signals; keep first per cluster."""
    rows=sorted(sig_rows, key=lambda r:int(r['time_msc']))
    keep=[]; last=None
    for r in rows:
        t=int(r['time_msc'])/1000.0
        if last is None or r['direction']!=last['direction'] or (t-int(last['time_msc'])/1000.0)>gap_s:
            keep.append(r); last=r
    return keep

def main(raw_p, fol_p, outdir):
    os.makedirs(outdir, exist_ok=True)
    raw=rd(raw_p); fol=rd(fol_p)
    byid={r['signal_id']:r for r in raw}
    print(f"raw signals={len(raw)} followups={len(fol)}")

    # normalized extended followups
    norm=[]; na=0
    for r in fol:
        eb=fnum(r['entry_bid']); ea=fnum(r['entry_ask'])
        xb=fnum(r['exit_bid']); xa=fnum(r['exit_ask'])
        s=byid.get(r['signal_id'])
        if s is None: continue
        if eb is None or ea is None or xb is None or xa is None:
            na+=1; continue
        pt=0.01
        net_buy=(xb-ea)/pt; net_sell=(eb-xa)/pt
        d=r['direction']; eng=net_buy if d=='BUY' else net_sell
        opp=net_sell if d=='BUY' else net_buy
        norm.append(dict(signal_id=r['signal_id'], direction=d, horizon=r['horizon'],
                         time_msc=int(s['time_msc']), hour=(int(s['time_msc'])//3600000)%24,
                         regime=s['regime'], families=s['families'], score=int(s['score']),
                         spread=fnum(s['spread_pts']),
                         net_buy=net_buy, net_sell=net_sell, engine_net=eng, opposite_net=opp,
                         coinflip=(net_buy+net_sell)/2.0,
                         mfe=fnum(r['mfe_pts']), mae=fnum(r['mae_pts']), ticks=int(r['ticks'])))
    with open(os.path.join(outdir,'extended_followups.csv'),'w',newline='') as f:
        w=csv.DictWriter(f, fieldnames=list(norm[0].keys())); w.writeheader(); w.writerows(norm)
    print(f"normalized rows={len(norm)} NA_rows={na}")

    # clustering (dedupe analysis only; raw preserved)
    raw_sig=[{'signal_id':s['signal_id'],'time_msc':s['time_msc'],'direction':s['direction']} for s in raw]
    keep=cluster(raw_sig, 60); keep_ids=set(k['signal_id'] for k in keep)
    print(f"clustered signals (gap<=60s same-dir) = {len(keep)} of {len(raw)}")

    # engine vs random baseline vs opposite, per horizon (raw + clustered)
    rb_rows=[]
    for scope, ids in [('raw', None), ('clustered', keep_ids)]:
        for h in HZ:
            sub=[x for x in norm if x['horizon']==h and (ids is None or x['signal_id'] in ids)]
            e=stats([x['engine_net'] for x in sub])
            c=stats([x['coinflip'] for x in sub])
            o=stats([x['opposite_net'] for x in sub])
            rb_rows.append(dict(scope=scope,horizon=h,n=e['n'],
                engine_mean=e['mean'],engine_lo=e['lo'],engine_hi=e['hi'],engine_pctpos=e['pctpos'],
                random_mean=c['mean'],opposite_mean=o['mean'],
                delta_vs_random=(None if e['mean'] is None else e['mean']-c['mean']),
                verdict=verdict(e['mean'],e['lo'],e['hi'],e['n'])))
    with open(os.path.join(outdir,'random_baseline.csv'),'w',newline='') as f:
        w=csv.DictWriter(f, fieldnames=list(rb_rows[0].keys())); w.writeheader(); w.writerows(rb_rows)

    # strategy performance (raw + clustered), 300s and 60s focus but all horizons
    sp_rows=[]
    for scope, ids in [('raw', None), ('clustered', keep_ids)]:
        fams=defaultdict(list)
        for x in norm:
            if ids is not None and x['signal_id'] not in ids: continue
            for fam in (x['families'] or '').split():
                fams[(fam,x['horizon'])].append(x['engine_net'])
        for (fam,h),vals in sorted(fams.items()):
            st=stats(vals)
            sp_rows.append(dict(scope=scope,family=fam,horizon=h,n=st['n'],mean=st['mean'],
                median=st['median'],pctpos=st['pctpos'],ci_lo=st['lo'],ci_hi=st['hi'],
                verdict=verdict(st['mean'],st['lo'],st['hi'],st['n'])))
    with open(os.path.join(outdir,'strategy_performance.csv'),'w',newline='') as f:
        w=csv.DictWriter(f, fieldnames=list(sp_rows[0].keys())); w.writeheader(); w.writerows(sp_rows)

    # session performance (server hour) raw + clustered, all horizons
    se_rows=[]
    for scope, ids in [('raw', None), ('clustered', keep_ids)]:
        hr=defaultdict(list)
        for x in norm:
            if ids is not None and x['signal_id'] not in ids: continue
            hr[(x['hour'],x['horizon'])].append(x['engine_net'])
        for (hh,h),vals in sorted(hr.items()):
            st=stats(vals)
            se_rows.append(dict(scope=scope,hour=hh,horizon=h,n=st['n'],mean=st['mean'],
                median=st['median'],pctpos=st['pctpos'],ci_lo=st['lo'],ci_hi=st['hi'],
                verdict=verdict(st['mean'],st['lo'],st['hi'],st['n'])))
    with open(os.path.join(outdir,'session_performance.csv'),'w',newline='') as f:
        w=csv.DictWriter(f, fieldnames=list(se_rows[0].keys())); w.writeheader(); w.writerows(se_rows)

    # regime performance included in report from norm
    print("wrote extended_followups.csv, random_baseline.csv, strategy_performance.csv, session_performance.csv")
    # stash summary for report generator
    import json
    json.dump(dict(n_signals=len(raw), n_norm=len(norm), na=na, n_clustered=len(keep),
                   rb=rb_rows), open(os.path.join(outdir,'_summary.json'),'w'))

if __name__=='__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
