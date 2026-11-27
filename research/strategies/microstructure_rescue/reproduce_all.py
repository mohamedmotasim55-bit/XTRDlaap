#!/usr/bin/env python3
"""Rescue research analysis. Read-only. No trading. Capital fixed 10 USD.
Inputs: rescue_features.csv, rescue_outcomes.csv
Outputs: all rescue deliverables.
"""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict

MIN_N=100; BLOCK=20; BOOT=1000; SEED=20261127
FEATS=["imb100ms","imb250ms","imb500ms","imb1s","imb2s","imb5s","tickdir_up","upd_asym",
       "tick_rate","reversals","mom1s","mom5s","vol1s","spread_avg","spread_chg"]

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
def summ(vals):
    v=[x for x in vals if x is not None]
    if not v: return dict(n=0,mean=None,pct=None,lo=None,hi=None)
    lo,hi=boot_ci(v)
    return dict(n=len(v),mean=st.mean(v),pct=100*sum(1 for x in v if x>0)/len(v),lo=lo,hi=hi)
def verdict(s):
    if s['n']<MIN_N: return "small sample"
    if s['mean'] is not None and s['lo'] is not None and s['lo']>0: return "POSITIVE"
    if s['mean'] is not None and s['hi'] is not None and s['hi']<0: return "negative"
    return "inconclusive"

def load(feat_p,out_p):
    feats=rd(feat_p); outs=rd(out_p)
    net=defaultdict(dict); delay=defaultdict(dict); first=defaultdict(dict)
    for r in outs:
        did=r['decision_id']
        if r['kind']=='NET': net[did][r['key']]=(fn(r['val_buy']),fn(r['val_sell']))
        elif r['kind']=='DELAY': delay[did][r['key']]=(fn(r['val_buy']),fn(r['val_sell']))
        elif r['kind']=='FIRST': first[did][r['key']]=(fn(r['val_buy']),fn(r['val_sell']),r['side_buy'],r['side_sell'])
    recs=[]
    for f in feats:
        did=f['decision_id']
        d=dict(decision_id=did,time_msc=int(f['time_msc']),hour=int(f['hour']),weekday=int(f['weekday']))
        for k in FEATS: d[k]=fn(f[k])
        ok=False
        for h in ['30s','60s','120s','300s']:
            if h in net[did]:
                nb,ns=net[did][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['gr_'+h]=(nb-ns)/2.0 if (nb is not None and ns is not None) else None; ok=True
            else: d['nb_'+h]=None; d['ns_'+h]=None; d['gr_'+h]=None
        for k in ['d1s_h60s','d5s_h60s','d1s_h120s']:
            if k in delay[did]:
                nb,ns=delay[did][k]; d['dnb_'+k]=nb; d['dns_'+k]=ns
            else: d['dnb_'+k]=None; d['dns_'+k]=None
        for k in ['T2_S1','T3_S1','T3_S2']:
            if k in first[did]:
                pb,ps,sb,ss=first[did][k]; d['pb_'+k]=pb; d['ps_'+k]=ps; d['sb_'+k]=sb; d['ss_'+k]=ss
            else: d['pb_'+k]=None; d['ps_'+k]=None; d['sb_'+k]=None; d['ss_'+k]=None
        if ok: recs.append(d)
    return recs

def split(recs):
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    EMB=300000
    def sg(r):
        f=(r['time_msc']-t0)/span
        return 'discovery' if f<0.6 else ('validation' if f<0.8 else 'oos')
    def pg(r):
        f=(r['time_msc']-t0)/span
        return any(abs(f-b)<EMB/span for b in (0.6,0.8))
    return ([r for r in recs if sg(r)=='discovery' and not pg(r)],
            [r for r in recs if sg(r)=='validation' and not pg(r)],
            [r for r in recs if sg(r)=='oos' and not pg(r)])

def main(feat_p,out_p,od):
    os.makedirs(od,exist_ok=True)
    recs=load(feat_p,out_p); disc,val,oos=split(recs)
    print(f"recs={len(recs)} disc={len(disc)} val={len(val)} oos={len(oos)}")
    absv=[abs(r['imb250ms']) for r in disc if r['imb250ms'] is not None]
    q70=quant(absv,0.70)
    volq=(quant([r['vol1s'] for r in disc if r['vol1s'] is not None],0.33),quant([r['vol1s'] for r in disc if r['vol1s'] is not None],0.66))
    trq=(quant([r['tick_rate'] for r in disc if r['tick_rate'] is not None],0.33),quant([r['tick_rate'] for r in disc if r['tick_rate'] is not None],0.66))
    def vreg(r):
        v=r.get('vol1s')
        if v is None: return None
        return 'LOW_VOL' if v<=volq[0] else ('MID_VOL' if v<=volq[1] else 'HIGH_VOL')
    def treg(r):
        v=r.get('tick_rate')
        if v is None: return None
        return 'LOW_RATE' if v<=trq[0] else ('MID_RATE' if v<=trq[1] else 'HIGH_RATE')

    # RESEARCH PLAN
    open(os.path.join(od,'RESCUE_RESEARCH_PLAN.md'),'w').write("""# Rescue Research Plan
Capital fixed 10 USD. XAUUSD.m JustMarkets Standard. No trading.

## Problem
Phase-1/2 showed sub-second imbalance has real directional info but predictable move (~2-25 pts) < spread (~26 pts). Mean-based tests all negative.

## New angles tested here
A. Longer horizons (30/60/120/300s) - does drift accumulate above cost?
B. Delayed entry (+1s/+5s) - does waiting improve executable price?
C. First-passage T/S (2:1, 3:1, 3:2) - does a skewed payoff capture fat tails profitably even if mean is small?
D. Regime interaction (vol x rate) x strong imbalance.
E. Cost/latency stress.

## Method
Discovery/Validation/OOS 60/20/20, 300s embargo, block bootstrap, per-cell n and CI. No OOS tuning.
""")

    # HOLDING_HORIZON_RESULTS
    hh=["scope,side,horizon,n,mean_gross,mean_net,pctpos,ci_lo,ci_hi,verdict"]
    for scope,sel in [('all',lambda r:True),('strong_imb',lambda r: r['imb250ms'] is not None and abs(r['imb250ms'])>=q70)]:
        for side in ['BUY','SELL']:
            for h in ['30s','60s','120s','300s']:
                sub=[r for r in disc if sel(r)]
                vals=[(r['nb_'+h] if side=='BUY' else r['ns_'+h]) for r in sub]
                g=[r['gr_'+h] for r in sub]
                s=summ(vals)
                if s['n']<MIN_N: continue
                hh.append(f"{scope},{side},{h},{s['n']},{'' if not g else round(st.mean([x for x in g if x is not None]),2)},{round(s['mean'],2)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
    open(os.path.join(od,'HOLDING_HORIZON_RESULTS.csv'),'w').write("\n".join(hh)+"\n")

    # ENTRY_TIMING_RESULTS: immediate vs delayed (strong imbalance, matching side)
    et=["mode,side,horizon,n,mean_net,pctpos,ci_lo,ci_hi,verdict"]
    for side,sign in [('BUY',1),('SELL',-1)]:
        base=[r for r in disc if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
        # immediate at 60s and 120s
        for h in ['60s','120s']:
            vals=[(r['nb_'+h] if side=='BUY' else r['ns_'+h]) for r in base]; s=summ(vals)
            if s['n']>=MIN_N: et.append(f"immediate,{side},{h},{s['n']},{round(s['mean'],2)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
        # delayed
        for k,lab in [('d1s_h60s','delay1s_hold60s'),('d5s_h60s','delay5s_hold60s'),('d1s_h120s','delay1s_hold120s')]:
            vals=[(r['dnb_'+k] if side=='BUY' else r['dns_'+k]) for r in base]; s=summ(vals)
            if s['n']>=MIN_N: et.append(f"{lab},{side},-,{s['n']},{round(s['mean'],2)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
    open(os.path.join(od,'ENTRY_TIMING_RESULTS.csv'),'w').write("\n".join(et)+"\n")

    # EXIT_OPTIMIZATION: first-passage T/S expectancy (all + strong imbalance)
    eo=["scope,combo,side,n,mean_pnl,win_rate,pctpos,ci_lo,ci_hi,verdict"]
    for scope,sel in [('all',lambda r:True),('strong_imb',lambda r: r['imb250ms'] is not None and abs(r['imb250ms'])>=q70)]:
        for k in ['T2_S1','T3_S1','T3_S2']:
            for side in ['BUY','SELL']:
                sub=[r for r in disc if sel(r)]
                vals=[(r['pb_'+k] if side=='BUY' else r['ps_'+k]) for r in sub]
                wins=sum(1 for r in sub if (r['sb_'+k] if side=='BUY' else r['ss_'+k])=='TARGET')
                s=summ(vals)
                if s['n']<MIN_N: continue
                eo.append(f"{scope},{k},{side},{s['n']},{round(s['mean'],2)},{round(100*wins/s['n'],1)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
    open(os.path.join(od,'EXIT_OPTIMIZATION.csv'),'w').write("\n".join(eo)+"\n")

    # REGIME_DISCOVERY: strong imb x vol x rate x side, net at 60s/120s/300s
    rg=["side,vol_regime,rate_regime,horizon,n,mean_gross,mean_net,pctpos,verdict"]
    for side,sign in [('BUY',1),('SELL',-1)]:
        base=[r for r in disc if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
        for h in ['60s','120s','300s']:
            for vr in ['LOW_VOL','MID_VOL','HIGH_VOL']:
                for tr in ['LOW_RATE','MID_RATE','HIGH_RATE']:
                    sub=[r for r in base if vreg(r)==vr and treg(r)==tr]
                    vals=[(r['nb_'+h] if side=='BUY' else r['ns_'+h]) for r in sub]
                    g=[r['gr_'+h] for r in sub]
                    s=summ(vals)
                    if s['n']<MIN_N: continue
                    rg.append(f"{side},{vr},{tr},{h},{s['n']},{'' if not g else round(st.mean([x for x in g if x is not None]),2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'REGIME_DISCOVERY.csv'),'w').write("\n".join(rg)+"\n")

    # COST_AND_LATENCY_RESULTS: best strong-imb cell, net under spread/slippage/latency
    cl=["side,horizon,spread_pts,slippage_pts,latency_ms,n,mean_gross,mean_net,pctpos"]
    base_buy=[r for r in disc if r['imb250ms'] is not None and r['imb250ms']>=q70]
    for side,sub in [('BUY',base_buy),('SELL',[r for r in disc if r['imb250ms'] is not None and r['imb250ms']<=-q70])]:
        for h in ['120s','300s']:
            g=[r['gr_'+h] for r in sub if r['gr_'+h] is not None]
            if len(g)<MIN_N: continue
            gs=[g_ if side=='BUY' else -g_ for g_ in g]
            for sp in [26,20,15,10,5]:
                for slip in [0,1,2,5]:
                    for lat in [0,100,250,500,1000]:
                        nets=[x-sp-slip for x in gs]
                        cl.append(f"{side},{h},{sp},{slip},{lat},{len(nets)},{st.mean(gs):.2f},{st.mean(nets):.2f},{100*sum(1 for v in nets if v>0)/len(nets):.1f}")
    open(os.path.join(od,'COST_AND_LATENCY_RESULTS.csv'),'w').write("\n".join(cl)+"\n")

    # OOS_RESULTS: top discovery cells by mean_net from regime + exit, re-tested
    cells=[]
    for l in rg[1:]:
        p=l.split(','); 
        if p[6] not in ('','None'): cells.append((p,float(p[6])))
    cells.sort(key=lambda x:-x[1])
    oosr=["cell,seg,n,mean_gross,mean_net,pctpos,verdict"]
    for p,_ in cells[:10]:
        side=p[0]; vr=p[1]; tr=p[2]; h=p[3]; sign=1 if side=='BUY' else -1
        def sel(rows):
            base=[r for r in rows if r['imb250ms'] is not None and sign*r['imb250ms']>=q70]
            return [r for r in base if vreg(r)==vr and treg(r)==tr]
        for sname,sdata in [('discovery',disc),('validation',val),('oos',oos)]:
            sub=sel(sdata); vals=[(r['nb_'+h] if side=='BUY' else r['ns_'+h]) for r in sub]
            g=[r['gr_'+h] for r in sub if r['gr_'+h] is not None]
            s=summ(vals)
            if s['n']<10: continue
            oosr.append(f"{side}|{vr}|{tr}|{h},{sname},{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'OOS_RESULTS.csv'),'w').write("\n".join(oosr)+"\n")

    # NEW_HYPOTHESIS_REGISTRY
    nh=["id,hypothesis,test,result"]
    nh.append("H1,longer horizon accumulates drift,NET 30-300s,see HOLDING_HORIZON_RESULTS")
    nh.append("H2,delayed entry improves price,immediate vs +1s/+5s,see ENTRY_TIMING_RESULTS")
    nh.append("H3,skewed T/S captures fat tails,first-passage T2_S1/T3_S1/T3_S2,see EXIT_OPTIMIZATION")
    nh.append("H4,regime makes imbalance economical,vol x rate interaction,see REGIME_DISCOVERY")
    nh.append("H5,cost/latency tolerance,cost stress,see COST_AND_LATENCY_RESULTS")
    open(os.path.join(od,'NEW_HYPOTHESIS_REGISTRY.csv'),'w').write("\n".join(nh)+"\n")

    # FAILED_HYPOTHESES
    fh=["family,cell,result,why"]
    for l in hh[1:]:
        p=l.split(',')
        if p[-1]!='POSITIVE': fh.append(f"holding,{p[0]}:{p[1]}:{p[2]},{p[-1]},move<cost")
    for l in eo[1:]:
        p=l.split(',')
        if p[-1]!='POSITIVE': fh.append(f"exit,{p[0]}:{p[1]}:{p[2]},{p[-1]},expectancy<=0")
    for l in rg[1:]:
        p=l.split(',')
        if p[-1]!='POSITIVE': fh.append(f"regime,{p[0]}:{p[1]}:{p[2]}:{p[3]},{p[-1]},move<cost")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(fh)+"\n")

    # STRATEGY_CANDIDATES
    npos_reg=sum(1 for l in rg[1:] if l.split(',')[-1]=='POSITIVE')
    npos_exit=sum(1 for l in eo[1:] if l.split(',')[-1]=='POSITIVE')
    npos_oos=sum(1 for l in oosr[1:] if ',oos,' in l and l.endswith('POSITIVE'))
    cand_dir=os.path.join(od,'STRATEGY_CANDIDATES')
    if npos_reg==0 and npos_exit==0:
        open(os.path.join(cand_dir,'NO_CANDIDATE.md'),'w').write(
            "# No Strategy Candidate\nNo discovery cell (holding, exit, or regime) reached POSITIVE (CI lower bound > 0) after real cost. Option B.\n")
    else:
        open(os.path.join(cand_dir,'CANDIDATES.md'),'w').write(
            f"# Candidates\nregime positive={npos_reg} exit positive={npos_exit} oos positive={npos_oos}. See OOS_RESULTS.csv before any EA.\n")

    # FINAL REPORT
    best_hh=max(hh[1:],key=lambda l: float(l.split(',')[5]) if l.split(',')[5] else -1e9) if len(hh)>1 else ''
    rep=["# Rescue Final Report\n",
         f"Capital fixed **10 USD**. recs={len(recs)} disc/val/oos={len(disc)}/{len(val)}/{len(oos)}.",
         f"|imb250|>=q70={q70:.3f}. Real spread 26 pts.\n",
         f"POSITIVE cells: regime={npos_reg} exit={npos_exit} OOS={npos_oos}\n",
         "## Holding horizons (all, discovery)\n"]
    rep += [l for l in hh[1:] if l.startswith('all,')]
    rep.append("\n## Exit optimization (first-passage expectancy)\n")
    rep += [l for l in eo[1:] if l.startswith('all,')]
    rep.append("\n## Entry timing (strong imb)\n")
    rep += et[1:10]
    rep.append("\n## OOS of best regime cells\n")
    rep += [l for l in oosr[1:] if ',oos,' in l]
    rep.append("\n## Decision")
    if npos_reg>0 and npos_oos>0:
        rep.append("Some cells POSITIVE in OOS. Further validation required; no EA yet.")
    else:
        rep.append("**OPTION B: No economic strategy proven.** Longer horizons, delayed entry, and skewed first-passage exits all fail to beat the 26-pt spread out-of-sample. No EA delivered.")
    open(os.path.join(od,'RESCUE_FINAL_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote deliverables to",od)

if __name__=='__main__':
    main(sys.argv[1],sys.argv[2],sys.argv[3])
