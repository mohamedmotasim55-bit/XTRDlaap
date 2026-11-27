#!/usr/bin/env python3
"""Microstructure strategy conditional discovery. Read-only. No trading.
Tests whether imbalance + market-state conditions yields net>0 after cost.
Capital fixed = 10 USD. Discovery/Validation/OOS with embargo + multiple-testing note.
"""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict

HZ = ["100ms","250ms","500ms","1s","2s","5s","10s"]
FEATS = ["imb100ms","imb250ms","imb500ms","imb1s","tick_rate","vol1s","mom1s","accel",
         "upd_asym","spread_avg","spread_chg","reversals","tickdir_up","iat_ms"]
MIN_N = 100
BLOCK = 20; BOOT = 1000; SEED = 20261127
SPREAD = 26.0

def rd(p):
    with open(p,newline='',encoding='utf-8',errors='ignore') as f: return list(csv.DictReader(f))
def fn(x):
    try:
        v=float(x); return v if math.isfinite(v) else None
    except: return None
def quant(vals,q):
    v=sorted(x for x in vals if x is not None)
    if not v: return None
    return v[int(q*(len(v)-1))]
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

def load(feat_p,out_p):
    feats=rd(feat_p); outs=rd(out_p)
    net=defaultdict(dict)
    for r in outs:
        nb=fn(r['net_buy']); ns=fn(r['net_sell'])
        if nb is not None and ns is not None: net[r['decision_id']][r['horizon']]=(nb,ns)
    recs=[]
    for f in feats:
        did=f['decision_id']
        d=dict(decision_id=did,time_msc=int(f['time_msc']),hour=int(f['hour']),weekday=int(f['weekday']))
        for k in FEATS: d[k]=fn(f[k])
        ok=False
        for h in HZ:
            if h in net[did]:
                nb,ns=net[did][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['gross_'+h]=(nb-ns)/2.0; ok=True
            else: d['nb_'+h]=None; d['ns_'+h]=None; d['gross_'+h]=None
        if ok: recs.append(d)
    return recs

def split(recs):
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    EMB=10000
    def sg(r):
        f=(r['time_msc']-t0)/span
        return 'discovery' if f<0.6 else ('validation' if f<0.8 else 'oos')
    def pg(r):
        f=(r['time_msc']-t0)/span
        return any(abs(f-b)<EMB/span for b in (0.6,0.8))
    return ([r for r in recs if sg(r)=='discovery' and not pg(r)],
            [r for r in recs if sg(r)=='validation' and not pg(r)],
            [r for r in recs if sg(r)=='oos' and not pg(r)])

def net_of(r,side,h):
    return r['nb_'+h] if side=='BUY' else r['ns_'+h]

def summarize(rows,side,h):
    vals=[net_of(r,side,h) for r in rows if net_of(r,side,h) is not None]
    if not vals: return dict(n=0,mean=None,pct=None,lo=None,hi=None,gross=None)
    lo,hi=boot_ci(vals)
    g=[r['gross_'+h] for r in rows if r['gross_'+h] is not None]
    return dict(n=len(vals),mean=st.mean(vals),pct=100*sum(1 for v in vals if v>0)/len(vals),
                lo=lo,hi=hi,gross=(st.mean(g) if g else None))

def verdict(s):
    if s['n']<MIN_N: return "small sample"
    if s['mean'] is not None and s['lo'] is not None and s['lo']>0: return "POSITIVE"
    if s['mean'] is not None and s['hi'] is not None and s['hi']<0: return "negative"
    return "inconclusive"

def main(feat_p,out_p,od):
    os.makedirs(od,exist_ok=True)
    recs=load(feat_p,out_p)
    disc,val,oos=split(recs)
    print(f"recs={len(recs)} disc={len(disc)} val={len(val)} oos={len(oos)}")

    # signal: strong imbalance. Use imb250ms magnitude quantiles on discovery.
    absv=[abs(r['imb250ms']) for r in disc if r['imb250ms'] is not None]
    q70=quant(absv,0.70); q85=quant(absv,0.85)
    # conditions from discovery quantiles
    volq=(quant([r['vol1s'] for r in disc if r['vol1s'] is not None],0.33),
          quant([r['vol1s'] for r in disc if r['vol1s'] is not None],0.66))
    trq=(quant([r['tick_rate'] for r in disc if r['tick_rate'] is not None],0.33),
         quant([r['tick_rate'] for r in disc if r['tick_rate'] is not None],0.66))
    spq=(quant([r['spread_avg'] for r in disc if r['spread_avg'] is not None],0.33),
         quant([r['spread_avg'] for r in disc if r['spread_avg'] is not None],0.66))
    print(f"q70|imb|={q70:.3f} q85={q85:.3f} volq={volq} trq={trq} spq={spq}")

    def regime(r,name):
        v=r.get(name)
        if v is None: return None
        if name=='vol1s':
            if v<=volq[0]: return 'LOW_VOL'
            if v<=volq[1]: return 'MID_VOL'
            return 'HIGH_VOL'
        if name=='tick_rate':
            if v<=trq[0]: return 'LOW_RATE'
            if v<=trq[1]: return 'MID_RATE'
            return 'HIGH_RATE'
        if name=='spread_avg':
            if v<=spq[0]: return 'TIGHT_SPREAD'
            if v<=spq[1]: return 'MID_SPREAD'
            return 'WIDE_SPREAD'
        return None

    # CONDITIONAL_STRATEGY_DISCOVERY: signal-dir x single condition x horizon (discovery)
    csd=["signal,condition,horizon,side,n,mean_gross,mean_net,pctpos,ci_lo,ci_hi,verdict"]
    conds=['vol1s','tick_rate','spread_avg','mom1s','session']
    for cond in conds:
        # build condition values
        if cond=='mom1s':
            def cval(r): return 'MOM_UP' if (r['mom1s'] or 0)>0 else 'MOM_DN'
        elif cond=='session':
            def cval(r): return f"H{r['hour']:02d}"
        else:
            def cval(r): return regime(r,cond)
        for thr_name,thr in [('strong',q70)]:
            for side,sign in [('BUY',1),('SELL',-1)]:
                base=[r for r in disc if r['imb250ms'] is not None and sign*r['imb250ms']>=thr]
                cells=defaultdict(list)
                for r in base:
                    c=cval(r)
                    if c: cells[c].append(r)
                for c,rows in sorted(cells.items()):
                    for h in HZ:
                        s=summarize(rows,side,h)
                        if s['n']<MIN_N: continue
                        csd.append(f"imb250_{thr_name}_{side},{cond}:{c},{h},{side},{s['n']},"
                                   f"{'' if s['gross'] is None else round(s['gross'],2)},{round(s['mean'],2)},{round(s['pct'],1)},"
                                   f"{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
    open(os.path.join(od,'CONDITIONAL_STRATEGY_DISCOVERY.csv'),'w').write("\n".join(csd)+"\n")

    # BUY_SELL_PERFORMANCE: overall strong signal, by side & horizon (discovery)
    bsp=["side,horizon,n,mean_gross,mean_net,pctpos,ci_lo,ci_hi,verdict"]
    for side,sign in [('BUY',1),('SELL',-1)]:
        base=[r for r in disc if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
        for h in HZ:
            s=summarize(base,side,h)
            if s['n']<MIN_N: continue
            bsp.append(f"{side},{h},{s['n']},{'' if s['gross'] is None else round(s['gross'],2)},{round(s['mean'],2)},{round(s['pct'],1)},"
                       f"{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
    open(os.path.join(od,'BUY_SELL_PERFORMANCE.csv'),'w').write("\n".join(bsp)+"\n")

    # REGIME_INTERACTIONS: strong signal x (vol,rate) joint, by side, at best horizon candidates
    ri=["side,vol_regime,rate_regime,horizon,n,mean_gross,mean_net,pctpos,verdict"]
    for side,sign in [('BUY',1),('SELL',-1)]:
        base=[r for r in disc if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
        for h in ['500ms','1s','2s']:
            for vr in ['LOW_VOL','MID_VOL','HIGH_VOL']:
                for tr in ['LOW_RATE','MID_RATE','HIGH_RATE']:
                    rows=[r for r in base if regime(r,'vol1s')==vr and regime(r,'tick_rate')==tr]
                    s=summarize(rows,side,h)
                    if s['n']<MIN_N: continue
                    ri.append(f"{side},{vr},{tr},{h},{s['n']},{'' if s['gross'] is None else round(s['gross'],2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'REGIME_INTERACTIONS.csv'),'w').write("\n".join(ri)+"\n")

    # ENTRY_EXIT_OPTIMIZATION: entry imbalance thresholds x hold horizon, best side, discovery
    eeo=["side,imb_threshold,horizon,n,mean_gross,mean_net,pctpos,verdict"]
    for side,sign in [('BUY',1),('SELL',-1)]:
        for tname,t in [('q50',quant(absv,0.50)),('q70',q70),('q85',q85),('q95',quant(absv,0.95))]:
            base=[r for r in disc if r['imb250ms'] is not None and sign*r['imb250ms']>=t]
            for h in HZ:
                s=summarize(base,side,h)
                if s['n']<MIN_N: continue
                eeo.append(f"{side},{tname}:{t:.2f},{h},{s['n']},{'' if s['gross'] is None else round(s['gross'],2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'ENTRY_EXIT_OPTIMIZATION.csv'),'w').write("\n".join(eeo)+"\n")

    # OOS_RESULTS: best discovery cells (by mean_net) re-tested on validation & oos
    cells=[l.split(',') for l in csd[1:]]
    # pick cells with highest mean_net in discovery
    cells_num=[(c,float(c[6])) for c in cells if c[6] not in ('','None')]
    cells_num.sort(key=lambda x:-x[1])
    oosr=["signal,condition,horizon,side,seg,n,mean_gross,mean_net,pctpos,verdict"]
    tested=0
    for c,_ in cells_num:
        if tested>=12: break
        sig=c[0]; condname=c[1]; h=c[2]; side=c[3]
        cond_key=condname.split(':',1)[1] if ':' in condname else condname
        cond=condname.split(':',1)[0]
        sign=1 if side=='BUY' else -1
        def sel(rows):
            base=[r for r in rows if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
            if cond=='mom1s':
                return [r for r in base if ('MOM_UP' if (r['mom1s'] or 0)>0 else 'MOM_DN')==cond_key]
            if cond=='session':
                return [r for r in base if f"H{r['hour']:02d}"==cond_key]
            return [r for r in base if regime(r,cond)==cond_key]
        tested+=1
        for sname,sdata in [('discovery',disc),('validation',val),('oos',oos)]:
            rows=sel(sdata); s=summarize(rows,side,h)
            if s['n']<10: continue
            oosr.append(f"{sig},{condname},{h},{side},{sname},{s['n']},{'' if s['gross'] is None else round(s['gross'],2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'OOS_RESULTS.csv'),'w').write("\n".join(oosr)+"\n")

    # COST_STRESS_TEST: for the best discovery cell, net under spread/slippage scenarios (oos)
    cst=["signal,condition,horizon,spread_pts,slippage_pts,n,mean_gross,mean_net,pctpos"]
    if cells_num:
        c=cells_num[0][0]; h=c[2]; side=c[3]; sign=1 if side=='BUY' else -1
        condname=c[1]; cond=condname.split(':',1)[0]; ck=condname.split(':',1)[1] if ':' in condname else condname
        base=[r for r in oos if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
        if cond=='mom1s': rows=[r for r in base if ('MOM_UP' if (r['mom1s'] or 0)>0 else 'MOM_DN')==ck]
        elif cond=='session': rows=[r for r in base if f"H{r['hour']:02d}"==ck]
        else: rows=[r for r in base if regime(r,cond)==ck]
        gross=[r['gross_'+h] for r in rows if r['gross_'+h] is not None]
        gsign=[sign*g for g in gross]
        for sp in [26,20,15,10,5,3]:
            for slip in [0,1,2,5]:
                nets=[g-sp-slip for g in gsign]
                if not nets: continue
                cst.append(f"{c[0]},{condname},{h},{sp},{slip},{len(nets)},{st.mean(gsign):.2f},{st.mean(nets):.2f},{100*sum(1 for v in nets if v>0)/len(nets):.1f}")
    open(os.path.join(od,'COST_STRESS_TEST.csv'),'w').write("\n".join(cst)+"\n")

    # FAILED_HYPOTHESES: all discovery cells that were not POSITIVE
    fh=["signal,condition,horizon,side,n,mean_net,verdict,why"]
    for c in cells:
        if c[10]!='POSITIVE':
            fh.append(f"{c[0]},{c[1]},{c[2]},{c[3]},{c[4]},{c[6]},{c[10]},move<cost or not significant")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(fh)+"\n")

    # REPORT
    npos=sum(1 for c in cells if c[10]=='POSITIVE')
    oos_pos=sum(1 for l in oosr[1:] if ',oos,' in l and l.endswith('POSITIVE'))
    rep=["# Microstructure Strategy Development (Phase 2)\n",
         f"Capital fixed **10 USD**. Decisions: {len(recs)}. Split {len(disc)}/{len(val)}/{len(oos)} (embargo 10s).",
         f"Signal: |imb250ms| >= q70={q70:.3f} (and q85={q85:.3f}). Cost: {SPREAD} pts spread.\n",
         f"Discovery cells tested: {len(cells)} | POSITIVE in discovery: {npos} | POSITIVE in OOS: {oos_pos}\n",
         "## Best discovery cells (top by mean_net)\n","| signal | condition | horizon | side | n | mean_net | verdict |","|---|---|---|---|---:|---:|---|"]
    for c,_ in cells_num[:10]:
        rep.append(f"| {c[0]} | {c[1]} | {c[2]} | {c[3]} | {c[4]} | {c[6]} | {c[10]} |")
    rep.append("\n## OOS check of best cells\n")
    rep.append("\n".join([l for l in oosr[1:] if ',oos,' in l][:15]))
    rep.append("\n## Cost stress (best cell, OOS)\n")
    rep.append("\n".join(cst[:12]))
    rep.append("\n## Decision")
    if oos_pos>0 and npos>0:
        rep.append("Candidate cells are POSITIVE in OOS; see OOS_RESULTS. Requires further validation before any EA.")
    else:
        rep.append("**Option B: No economic strategy proven.** Predictable moves stay below execution cost; no conditional cell is positive out-of-sample after cost.")
    open(os.path.join(od,'MICROSTRUCTURE_STRATEGY_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote deliverables to",od)

if __name__=='__main__':
    main(sys.argv[1],sys.argv[2],sys.argv[3])
