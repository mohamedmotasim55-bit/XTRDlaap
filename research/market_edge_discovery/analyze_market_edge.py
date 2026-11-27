#!/usr/bin/env python3
"""Market edge discovery analysis. Read-only. No trading, no tuning.
Inputs : edge_events.csv, edge_outcomes.csv (from XTRD_EDGE_DISCOVERY.mq5)
Outputs: data_quality_audit.md, feature_discovery.csv, hypothesis_performance.csv,
         session_regime_analysis.csv, random_baseline_comparison.csv,
         out_of_sample_results.csv, market_edge_report.md
"""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict

HZ=["1s","3s","5s","10s","30s","60s","120s","300s"]
MIN_N=200
BLOCK=20; BOOT=2000; SEED=20261127
PT=0.01

def rd(p):
    with open(p,newline='',encoding='utf-8',errors='ignore') as f: return list(csv.DictReader(f))
def fn(x):
    try:
        v=float(x); return v if math.isfinite(v) else None
    except: return None

def boot_ci(vals, block=BLOCK, boot=BOOT, seed=SEED):
    v=[x for x in vals if x is not None]; n=len(v)
    if n<10: return (None,None)
    rng=random.Random(seed); nb=max(1,math.ceil(n/block)); mx=max(1,n-block+1)
    means=[]
    for _ in range(boot):
        s=[]
        for _ in range(nb):
            k=rng.randrange(0,mx); s.extend(v[k:k+block])
        s=s[:n]; means.append(sum(s)/len(s))
    means.sort()
    return (means[int(0.025*(len(means)-1))], means[int(0.975*(len(means)-1))])

def verdict(mean,lo,hi,n):
    if n<MIN_N: return "small sample — no verdict"
    if mean is not None and lo is not None and lo>0: return "Positive evidence"
    if mean is not None and hi is not None and hi<0: return "Negative evidence"
    return "Inconclusive"

def summ(vals):
    v=[x for x in vals if x is not None]
    if not v: return dict(n=0,mean=None,med=None,pct=None,lo=None,hi=None)
    lo,hi=boot_ci(v)
    return dict(n=len(v),mean=st.mean(v),med=st.median(v),pct=100*sum(1 for x in v if x>0)/len(v),lo=lo,hi=hi)

def cluster(events, gap=60):
    ev=sorted(events,key=lambda r:int(r['time_msc'])); keep=[]; last={}
    for r in ev:
        t=int(r['time_msc'])/1000.0; ty=r['type']
        if ty not in last or t-last[ty]>gap:
            keep.append(r); last[ty]=t
    return keep

def main(ev_p, out_p, od):
    os.makedirs(od,exist_ok=True)
    ev=rd(ev_p); out=rd(out_p)
    evby={r['event_id']:r for r in ev}
    # build per-event records
    recs=[]; na=0
    for r in out:
        e=evby.get(r['event_id'])
        if e is None: continue
        eb=fn(r['entry_bid']); ea=fn(r['entry_ask']); xb=fn(r['exit_bid']); xa=fn(r['exit_ask'])
        if eb is None or ea is None or xb is None or xa is None:
            na+=1; continue
        nb=(xb-ea)/PT; ns=(eb-xa)/PT
        d=r['direction']; eng=nb if d=='BUY' else ns; opp=ns if d=='BUY' else nb
        recs.append(dict(event_id=r['event_id'],type=e['type'],direction=d,horizon=r['horizon'],
            time_msc=int(e['time_msc']),hour=int(e['hour']),wday=int(e['weekday']),
            regime=regime_of(e),spread=fn(e['spread_pts']),atr=fn(e['atr_pts']),
            z=fn(e['z']),v3=fn(e['v3s']),
            net_buy=nb,net_sell=ns,engine=eng,opposite=opp,coinflip=(nb+ns)/2.0,
            mfe=fn(r['mfe_pts']),mae=fn(r['mae_pts']),ticks=int(r['ticks'])))
    print(f"events={len(ev)} outcomes={len(out)} usable={len(recs)} NA={na}")

    # ---------- 1. data quality ----------
    spreads=[x['spread'] for x in recs if x['spread'] is not None]
    ticks=[x['ticks'] for x in recs]
    zs=[x['z'] for x in recs if x['z'] is not None]
    types=defaultdict(int)
    for e in ev: types[e['type']]+=1
    dq=["# Data Quality Audit\n",
        f"- events: {len(ev)} | outcome rows: {len(out)} | usable numeric: {len(recs)} | NA rows: {na}",
        f"- event types: {dict(types)}",
        f"- spread pts: median={st.median(spreads):.1f} p95={sorted(spreads)[int(0.95*len(spreads))]:.1f} min={min(spreads):.1f} max={max(spreads):.1f}" if spreads else "- spread: none",
        f"- ticks per outcome: median={st.median(ticks):.0f} min={min(ticks)} max={max(ticks)}",
        f"- NA policy: missing forward ticks written as NA, never invented.",
        "- price/points: point=0.01, net_pts computed from real bid/ask (BUY ask->bid, SELL bid->ask).",
        "- tick volume/imbalance treated as activity proxy only, NOT real order flow."]
    open(os.path.join(od,'data_quality_audit.md'),'w').write("\n".join(dq)+"\n")

    # ---------- clustering ----------
    keep=cluster([{'event_id':e['event_id'],'time_msc':e['time_msc'],'type':e['type']} for e in ev],60)
    keep_ids=set(k['event_id'] for k in keep)

    # ---------- 2. feature discovery (per type: feature means vs net at 60s) ----------
    fd=["type,feature,horizon,n,feat_mean,net_mean,corr_feat_net"]
    for ty in sorted(types):
        for h in ["10s","60s","300s"]:
            sub=[x for x in recs if x['type']==ty and x['horizon']==h]
            for feat in ['atr','spread','z','v3']:
                xs=[x[feat] for x in sub if x[feat] is not None]
                ys=[x['engine'] for x in sub if x[feat] is not None]
                if len(xs)>10:
                    mx=st.mean(xs); my=st.mean(ys)
                    cov=sum((a-mx)*(b-my) for a,b in zip(xs,ys))/len(xs)
                    sx=math.sqrt(sum((a-mx)**2 for a in xs)/len(xs)); sy=math.sqrt(sum((b-my)**2 for b in ys)/len(ys))
                    corr=cov/(sx*sy) if sx>0 and sy>0 else 0.0
                    fd.append(f"{ty},{feat},{h},{len(xs)},{mx:.4f},{my:.2f},{corr:.4f}")
    open(os.path.join(od,'feature_discovery.csv'),'w').write("\n".join(fd)+"\n")

    # ---------- 3. hypothesis performance (raw + clustered) ----------
    hp=["scope,type,direction,horizon,n,mean,median,pctpos,ci_lo,ci_hi,verdict"]
    for scope,ids in [('raw',None),('clustered',keep_ids)]:
        for ty in sorted(types):
            for d in ['BUY','SELL','ALL']:
                for h in HZ:
                    sub=[x for x in recs if x['type']==ty and x['horizon']==h and
                         (ids is None or x['event_id'] in ids) and (d=='ALL' or x['direction']==d)]
                    s=summ([x['engine'] for x in sub])
                    v=verdict(s['mean'],s['lo'],s['hi'],s['n'])
                    hp.append(f"{scope},{ty},{d},{h},{s['n']},{'' if s['mean'] is None else round(s['mean'],2)},"
                              f"{'' if s['med'] is None else round(s['med'],2)},{'' if s['pct'] is None else round(s['pct'],1)},"
                              f"{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{v}")
    open(os.path.join(od,'hypothesis_performance.csv'),'w').write("\n".join(hp)+"\n")

    # ---------- 4. session / regime ----------
    sr=["scope,type,hour,n,mean,pctpos,verdict"]
    for ty in sorted(types):
        for hh in range(24):
            sub=[x for x in recs if x['type']==ty and x['horizon']=='60s' and x['hour']==hh]
            s=summ([x['engine'] for x in sub])
            sr.append(f"raw,{ty},{hh},{s['n']},{'' if s['mean'] is None else round(s['mean'],2)},{'' if s['pct'] is None else round(s['pct'],1)},{verdict(s['mean'],s['lo'],s['hi'],s['n'])}")
    for reg in ['LOW_VOL','MID_VOL','HIGH_VOL']:
        for ty in sorted(types):
            sub=[x for x in recs if x['type']==ty and x['horizon']=='60s' and x['regime']==reg]
            s=summ([x['engine'] for x in sub])
            sr.append(f"regime,{ty}:{reg},{''},{s['n']},{'' if s['mean'] is None else round(s['mean'],2)},{'' if s['pct'] is None else round(s['pct'],1)},{verdict(s['mean'],s['lo'],s['hi'],s['n'])}")
    open(os.path.join(od,'session_regime_analysis.csv'),'w').write("\n".join(sr)+"\n")

    # ---------- 5. random baseline ----------
    rb=["type,horizon,n,engine_mean,random_mean,opposite_mean,delta_vs_random,ci_lo,ci_hi,verdict"]
    for ty in sorted(types):
        for h in HZ:
            sub=[x for x in recs if x['type']==ty and x['horizon']==h]
            e=summ([x['engine'] for x in sub]); c=summ([x['coinflip'] for x in sub]); o=summ([x['opposite'] for x in sub])
            rb.append(f"{ty},{h},{e['n']},{'' if e['mean'] is None else round(e['mean'],2)},"
                      f"{'' if c['mean'] is None else round(c['mean'],2)},{'' if o['mean'] is None else round(o['mean'],2)},"
                      f"{'' if e['mean'] is None or c['mean'] is None else round(e['mean']-c['mean'],2)},"
                      f"{'' if e['lo'] is None else round(e['lo'],2)},{'' if e['hi'] is None else round(e['hi'],2)},"
                      f"{verdict(e['mean'],e['lo'],e['hi'],e['n'])}")
    open(os.path.join(od,'random_baseline_comparison.csv'),'w').write("\n".join(rb)+"\n")

    # ---------- 6. out of sample (time split 60/20/20) ----------
    allt=sorted(set(x['time_msc'] for x in recs))
    if allt:
        t0,t1=allt[0],allt[-1]; span=t1-t0 if t1>t0 else 1
        def seg(t):
            f=(t-t0)/span
            return 'discovery' if f<0.6 else ('validation' if f<0.8 else 'oos')
        oos=["segment,type,horizon,n,mean,ci_lo,ci_hi,verdict"]
        for sname in ['discovery','validation','oos']:
            for ty in sorted(types):
                for h in HZ:
                    sub=[x for x in recs if x['type']==ty and x['horizon']==h and seg(x['time_msc'])==sname]
                    s=summ([x['engine'] for x in sub])
                    oos.append(f"{sname},{ty},{h},{s['n']},{'' if s['mean'] is None else round(s['mean'],2)},"
                               f"{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},"
                               f"{verdict(s['mean'],s['lo'],s['hi'],s['n'])}")
        open(os.path.join(od,'out_of_sample_results.csv'),'w').write("\n".join(oos)+"\n")

    print("wrote all deliverables to", od)

def regime_of(e):
    a=fn(e['atr_pts'])
    if a is None: return 'NA'
    if a < 100: return 'LOW_VOL'
    if a < 200: return 'MID_VOL'
    return 'HIGH_VOL'

if __name__=='__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
