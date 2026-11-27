#!/usr/bin/env python3
"""Next-generation strategy discovery analysis. Read-only. No trading. Capital 10 USD.
Inputs: ng_events.csv, ng_outcomes.csv
"""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict
HZ=["10s","30s","60s","120s","300s","600s","1800s"]
MIN_N=100; BLOCK=20; BOOT=1000; SEED=20261127
FAMS=["IMPULSE","SWEEP","COMPRESSION_BREAK","SESSION"]
def rd(p):
    with open(p,newline='',encoding='utf-8',errors='ignore') as f: return list(csv.DictReader(f))
def fn(x):
    try:
        v=float(x); return v if math.isfinite(v) else None
    except: return None
def boot_ci(vals, block=BLOCK, boot=BOOT, seed=SEED):
    v=[x for x in vals if x is not None]; n=len(v)
    if n<10: return (None,None)
    rng=random.Random(seed); nb=max(1,math.ceil(n/block)); mx=max(1,n-block+1); m=[]
    for _ in range(boot):
        s=[]
        for _ in range(nb):
            k=rng.randrange(0,mx); s.extend(v[k:k+block])
        s=s[:n]; m.append(sum(s)/len(s))
    m.sort(); return (m[int(0.025*(len(m)-1))], m[int(0.975*(len(m)-1))])
def summ(vals):
    v=[x for x in vals if x is not None]
    if not v: return dict(n=0,mean=None,pct=None,lo=None,hi=None)
    lo,hi=boot_ci(v); return dict(n=len(v),mean=st.mean(v),pct=100*sum(1 for x in v if x>0)/len(v),lo=lo,hi=hi)
def verdict(s):
    if s['n']<MIN_N: return "small sample"
    if s['mean'] is not None and s['lo'] is not None and s['lo']>0: return "POSITIVE"
    if s['mean'] is not None and s['hi'] is not None and s['hi']<0: return "negative"
    return "inconclusive"
def load(ev_p,out_p):
    ev=rd(ev_p); outs=rd(out_p)
    net=defaultdict(dict)
    for r in outs:
        nb=fn(r['net_buy']); ns=fn(r['net_sell'])
        if nb is not None and ns is not None: net[r['event_id']][r['horizon']]=(nb,ns)
    recs=[]
    for e in ev:
        eid=e['event_id']
        d=dict(event_id=eid,time_msc=int(e['time_msc']),family=e['family'],direction=e['direction'],
               hour=int(e['hour']),weekday=int(e['weekday']),spread=fn(e['spread_pts']),
               atr=fn(e['atr60']),rng=fn(e['range']),comp=fn(e['comp']))
        ok=False
        for h in HZ:
            if h in net[eid]:
                nb,ns=net[eid][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['gr_'+h]=(nb-ns)/2.0; ok=True
            else: d['nb_'+h]=None; d['ns_'+h]=None; d['gr_'+h]=None
        if ok: recs.append(d)
    return recs
def split(recs):
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    EMB=1800000
    def sg(r):
        f=(r['time_msc']-t0)/span
        return 'discovery' if f<0.6 else ('validation' if f<0.8 else 'oos')
    def pg(r):
        f=(r['time_msc']-t0)/span
        return any(abs(f-b)<EMB/span for b in (0.6,0.8))
    return ([r for r in recs if sg(r)=='discovery' and not pg(r)],
            [r for r in recs if sg(r)=='validation' and not pg(r)],
            [r for r in recs if sg(r)=='oos' and not pg(r)])
def main(ev_p,out_p,od):
    os.makedirs(od,exist_ok=True)
    recs=load(ev_p,out_p); disc,val,oos=split(recs)
    print(f"recs={len(recs)} disc={len(disc)} val={len(val)} oos={len(oos)}")
    fams=sorted(set(r['family'] for r in recs))
    # MARKET_OPPORTUNITY_MAP
    mo=["family,direction,events_per_day,mean_gross_60s,mean_net_60s"]
    for f in fams:
        sub=[r for r in recs if r['family']==f]
        for dr in ['BUY','SELL']:
            s=[r for r in sub if r['direction']==dr]
            if not s: continue
            g=[r['gr_60s'] for r in s if r['gr_60s'] is not None]
            n=[(r['nb_60s'] if dr=='BUY' else r['ns_60s']) for r in s]
            mo.append(f"{f},{dr},{len(s)/59.0:.1f},{'' if not g else round(st.mean(g),2)},{'' if not n else round(st.mean([x for x in n if x is not None]),2)}")
    open(os.path.join(od,'MARKET_OPPORTUNITY_MAP.csv'),'w').write("\n".join(mo)+"\n")
    # HYPOTHESIS_REGISTRY
    hr=["id,family,hypothesis,result"]
    for f in fams: hr.append(f"H_{f},{f},event direction persists after detection,see {f}_RESULTS.csv")
    hr.append("H_CROSS,cross_asset,gold vs DXY/silver lead-lag,NOT TESTED (no external data in MT5 tick feed)")
    open(os.path.join(od,'HYPOTHESIS_REGISTRY.csv'),'w').write("\n".join(hr)+"\n")
    # per-family results
    allres=[]
    for f in fams:
        rows=[f"family,direction,horizon,n,mean_gross,mean_net,pctpos,ci_lo,ci_hi,verdict"]
        for dr in ['BUY','SELL']:
            for h in HZ:
                sub=[r for r in disc if r['family']==f and r['direction']==dr]
                vals=[(r['nb_'+h] if dr=='BUY' else r['ns_'+h]) for r in sub]
                g=[r['gr_'+h] for r in sub if r['gr_'+h] is not None]
                s=summ(vals)
                if s['n']<MIN_N: continue
                rows.append(f"{f},{dr},{h},{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
                allres.append((f,dr,h,s,round(st.mean(g),2) if g else None))
        fname={'IMPULSE':'IMPULSE_RESULTS.csv','SWEEP':'LIQUIDITY_SWEEP_RESULTS.csv','COMPRESSION_BREAK':'COMPRESSION_BREAKOUT_RESULTS.csv','SESSION':'SESSION_RESULTS.csv'}.get(f,f+'_RESULTS.csv')
        open(os.path.join(od,fname),'w').write("\n".join(rows)+"\n")
    # CROSS_ASSET_RESULTS (data limitation)
    open(os.path.join(od,'CROSS_ASSET_RESULTS.csv'),'w').write("asset,status,note\nDXY,NOT_TESTED,no external data in MT5 XAUUSD.m tick feed\nXAGUSD,NOT_TESTED,not collected\nBONDS,NOT_TESTED,not collected\nNEWS,NOT_TESTED,no calendar data collected\n")
    # BUY_SELL_PERFORMANCE (all families, 60s)
    bsp=["family,side,horizon,n,mean_gross,mean_net,pctpos,verdict"]
    for f in fams:
        for dr in ['BUY','SELL']:
            sub=[r for r in disc if r['family']==f and r['direction']==dr]
            vals=[(r['nb_60s'] if dr=='BUY' else r['ns_60s']) for r in sub]
            g=[r['gr_60s'] for r in sub if r['gr_60s'] is not None]
            s=summ(vals)
            if s['n']<MIN_N: continue
            bsp.append(f"{f},{dr},60s,{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'BUY_SELL_PERFORMANCE.csv'),'w').write("\n".join(bsp)+"\n")
    # ENTRY_EXIT_RESULTS (holding horizon table per family, 60/120/300s)
    ee=["family,side,horizon,n,mean_net,verdict"]
    for f in fams:
        for dr in ['BUY','SELL']:
            for h in ['60s','120s','300s']:
                sub=[r for r in disc if r['family']==f and r['direction']==dr]
                vals=[(r['nb_'+h] if dr=='BUY' else r['ns_'+h]) for r in sub]
                s=summ(vals)
                if s['n']<MIN_N: continue
                ee.append(f"{f},{dr},{h},{s['n']},{round(s['mean'],2)},{verdict(s)}")
    open(os.path.join(od,'ENTRY_EXIT_RESULTS.csv'),'w').write("\n".join(ee)+"\n")
    # COST_STRESS_TEST (best family cell)
    cs=["family,side,horizon,spread_pts,slippage_pts,n,mean_gross,mean_net,pctpos"]
    best=max(allres,key=lambda x:x[3]['mean'] if x[3]['mean'] is not None else -1e9)
    bf,bd,bh,bs,bg=best
    sub=[r for r in disc if r['family']==bf and r['direction']==bd]
    gs=[r['gr_'+bh] for r in sub if r['gr_'+bh] is not None]
    gsign=[(g if bd=='BUY' else -g) for g in gs]
    for sp in [26,20,15,10,5]:
        for slip in [0,1,2,5]:
            nets=[x-sp-slip for x in gsign]
            cs.append(f"{bf},{bd},{bh},{sp},{slip},{len(nets)},{st.mean(gsign):.2f},{st.mean(nets):.2f},{100*sum(1 for v in nets if v>0)/len(nets):.1f}")
    open(os.path.join(od,'COST_STRESS_TEST.csv'),'w').write("\n".join(cs)+"\n")
    # OOS_RESULTS: best cells per family re-tested
    oosr=["family,side,horizon,seg,n,mean_gross,mean_net,pctpos,verdict"]
    for f in fams:
        # best cell for this family in discovery
        fc=[x for x in allres if x[0]==f]
        if not fc: continue
        bc=max(fc,key=lambda x:x[3]['mean'] if x[3]['mean'] is not None else -1e9)
        _,bd,bh,_,_=bc
        for sname,sdata in [('discovery',disc),('validation',val),('oos',oos)]:
            sub=[r for r in sdata if r['family']==f and r['direction']==bd]
            vals=[(r['nb_'+bh] if bd=='BUY' else r['ns_'+bh]) for r in sub]
            g=[r['gr_'+bh] for r in sub if r['gr_'+bh] is not None]
            s=summ(vals)
            if s['n']<10: continue
            oosr.append(f"{f},{bd},{bh},{sname},{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'OOS_RESULTS.csv'),'w').write("\n".join(oosr)+"\n")
    # FAILED_HYPOTHESES
    fh=["family,side,horizon,n,mean_net,verdict"]
    for x in allres:
        if x[3]['n']>=MIN_N and x[3]['mean'] is not None and x[3]['mean']<0:
            fh.append(f"{x[0]},{x[1]},{x[2]},{x[3]['n']},{round(x[3]['mean'],2)},{verdict(x[3])}")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(fh)+"\n")
    # STRATEGY_RANKING
    npos=sum(1 for x in allres if verdict(x[3])=='POSITIVE')
    oos_pos=sum(1 for l in oosr[1:] if ',oos,' in l and l.endswith('POSITIVE'))
    rank=["rank,family,best_side,best_horizon,n,mean_net,verdict,oos_positive"]
    fam_best=[]
    for f in fams:
        fc=[x for x in allres if x[0]==f]
        if not fc: continue
        bc=max(fc,key=lambda x:x[3]['mean'] if x[3]['mean'] is not None else -1e9)
        fam_best.append((f,bc))
    fam_best.sort(key=lambda x:-(x[1][3]['mean'] if x[1][3]['mean'] is not None else -1e9))
    for i,(f,bc) in enumerate(fam_best):
        rank.append(f"{i+1},{f},{bc[1]},{bc[2]},{bc[3]['n']},{round(bc[3]['mean'],2)},{verdict(bc[3])},{'yes' if oos_pos>0 else 'no'}")
    open(os.path.join(od,'STRATEGY_RANKING.csv'),'w').write("\n".join(rank)+"\n")
    # PLAN
    open(os.path.join(od,'STRATEGY_DISCOVERY_PLAN.md'),'w').write("""# Next-Generation Strategy Discovery Plan
Capital fixed 10 USD. XAUUSD.m JustMarkets Standard. No trading.
Families: IMPULSE (expansion), SWEEP (liquidity sweep reversal), COMPRESSION_BREAK (compression breakout), SESSION (London/NY open).
Cross-asset: NOT TESTED (no DXY/silver/news data in MT5 tick feed) - documented limitation.
Method: Discovery/Validation/OOS 60/20/20, 1800s embargo, block bootstrap, per-cell n/CI, BUY/SELL independent.
""")
    # REPORT
    rep=["# Next-Generation Strategy Report\n",
         f"Capital fixed **10 USD**. events={len(recs)} disc/val/oos={len(disc)}/{len(val)}/{len(oos)}.",
         f"Families: {fams}. Spread ~26 pts.\n",
         f"POSITIVE cells: {npos} | POSITIVE in OOS: {oos_pos}\n",
         "## Ranking\n","\n".join(rank),
         "\n## Family best (discovery)\n"]
    for f,bc in fam_best:
        rep.append(f"- {f} {bc[1]} {bc[2]}: n={bc[3]['n']} mean_net={round(bc[3]['mean'],2)} {verdict(bc[3])}")
    rep.append("\n## Decision")
    if npos>0 and oos_pos>0:
        rep.append("Candidate found - requires independent EA validation before adoption.")
    else:
        rep.append("**No next-generation family produced a positive-expectancy cell out-of-sample after real cost.** No EA delivered. Cross-asset data missing - next step is to collect DXY/silver/news and re-test.")
    open(os.path.join(od,'NEXT_GENERATION_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote deliverables to",od, "npos=",npos,"oos_pos=",oos_pos)
if __name__=='__main__':
    main(sys.argv[1],sys.argv[2],sys.argv[3])
