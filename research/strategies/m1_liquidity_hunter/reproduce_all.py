#!/usr/bin/env python3
"""M1 liquidity hunter research analysis. Read-only. No trading. Capital 10 USD."""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict
HZ=["1m","3m","5m","10m","30m","60m"]
MIN_N=100; BLOCK=20; BOOT=1000; SEED=20261127
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
    net=defaultdict(dict); first=defaultdict(dict)
    for r in outs:
        eid=r['event_id']
        if r['kind']=='NET': net[eid][r['key']]=(fn(r['val_buy']),fn(r['val_sell']))
        elif r['kind']=='FIRST': first[eid][r['key']]=(fn(r['val_buy']),fn(r['val_sell']),r['side_buy'],r['side_sell'])
    recs=[]
    for e in ev:
        eid=e['event_id']
        d=dict(event_id=eid,time_msc=int(e['time_msc']),kind=e['kind'],direction=e['direction'],
               hour=int(e['hour']),weekday=int(e['weekday']),spread=fn(e['spread_pts']),R=fn(e['R_pts']),
               mss=int(e['mss']),disp=int(e['disp']),mom=int(e['mom']))
        ok=False
        for h in HZ:
            if h in net[eid]:
                nb,ns=net[eid][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['gr_'+h]=(nb-ns)/2.0; ok=True
            else: d['nb_'+h]=None; d['ns_'+h]=None; d['gr_'+h]=None
        if '2R_1R' in first[eid]:
            pb,ps,sb,ss=first[eid]['2R_1R']; d['pb']=pb; d['ps']=ps; d['sb']=sb; d['ss']=ss
        else: d['pb']=None; d['ps']=None; d['sb']=None; d['ss']=None
        if ok: recs.append(d)
    return recs
def split(recs):
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    EMB=3600000
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
    kinds=sorted(set(r['kind'] for r in recs))
    # LIQUIDITY_MAP_AUDIT
    lm=["kind,direction,n,events_per_day,mean_R_pts,mss_rate,disp_rate"]
    for k in kinds:
        for dr in ['BUY','SELL']:
            s=[r for r in recs if r['kind']==k and r['direction']==dr]
            if not s: continue
            R=[r['R'] for r in s if r['R'] is not None]
            lm.append(f"{k},{dr},{len(s)},{len(s)/59.0:.2f},{'' if not R else round(st.mean(R),1)},{100*sum(1 for r in s if r['mss'])/len(s):.1f},{100*sum(1 for r in s if r['disp'])/len(s):.1f}")
    open(os.path.join(od,'LIQUIDITY_MAP_AUDIT.csv'),'w').write("\n".join(lm)+"\n")
    # SWEEP_DETECTION_RESULTS
    sw=["kind,direction,horizon,n,mean_gross,mean_net,pctpos,ci_lo,ci_hi,verdict"]
    allres=[]
    for k in kinds:
        for dr in ['BUY','SELL']:
            for h in HZ:
                sub=[r for r in disc if r['kind']==k and r['direction']==dr]
                vals=[(r['nb_'+h] if dr=='BUY' else r['ns_'+h]) for r in sub]
                g=[r['gr_'+h] for r in sub if r['gr_'+h] is not None]
                s=summ(vals)
                if s['n']<MIN_N: continue
                sw.append(f"{k},{dr},{h},{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
                allres.append((k,dr,h,s,round(st.mean(g),2) if g else None))
    open(os.path.join(od,'SWEEP_DETECTION_RESULTS.csv'),'w').write("\n".join(sw)+"\n")
    # CONFIRMATION_ABLATION (with/without each confirmation, sweeps only, 5m)
    ca=["confirmation,state,side,horizon,n,mean_net,verdict"]
    for k in ['SWEEP_PD_HIGH','SWEEP_PD_LOW','SWEEP_SW_HIGH','SWEEP_SW_LOW']:
        for cf in ['mss','disp','mom']:
            for state in [0,1]:
                for dr in ['BUY','SELL']:
                    sub=[r for r in disc if r['kind']==k and r['direction']==dr and r[cf]==state]
                    vals=[(r['nb_5m'] if dr=='BUY' else r['ns_5m']) for r in sub]
                    s=summ(vals)
                    if s['n']<MIN_N: continue
                    ca.append(f"{cf},{state},{dr},5m,{s['n']},{round(s['mean'],2)},{verdict(s)}")
    open(os.path.join(od,'CONFIRMATION_ABLATION.csv'),'w').write("\n".join(ca)+"\n")
    # BUY_SELL_PERFORMANCE (sweeps, 5m)
    bsp=["kind,side,horizon,n,mean_gross,mean_net,pctpos,verdict"]
    for k in kinds:
        for dr in ['BUY','SELL']:
            sub=[r for r in disc if r['kind']==k and r['direction']==dr]
            vals=[(r['nb_5m'] if dr=='BUY' else r['ns_5m']) for r in sub]
            g=[r['gr_5m'] for r in sub if r['gr_5m'] is not None]
            s=summ(vals)
            if s['n']<MIN_N: continue
            bsp.append(f"{k},{dr},5m,{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'BUY_SELL_PERFORMANCE.csv'),'w').write("\n".join(bsp)+"\n")
    # ENTRY_OPTIMIZATION (holding horizons per sweep kind)
    eo=["kind,side,horizon,n,mean_net,verdict"]
    for k in ['SWEEP_PD_HIGH','SWEEP_PD_LOW','SWEEP_SW_HIGH','SWEEP_SW_LOW']:
        for dr in ['BUY','SELL']:
            for h in HZ:
                sub=[r for r in disc if r['kind']==k and r['direction']==dr]
                vals=[(r['nb_'+h] if dr=='BUY' else r['ns_'+h]) for r in sub]
                s=summ(vals)
                if s['n']<MIN_N: continue
                eo.append(f"{k},{dr},{h},{s['n']},{round(s['mean'],2)},{verdict(s)}")
    open(os.path.join(od,'ENTRY_OPTIMIZATION.csv'),'w').write("\n".join(eo)+"\n")
    # EXIT_OPTIMIZATION (2R/1R first-passage expectancy)
    xo=["scope,side,n,mean_pnl,win_rate,pctpos,ci_lo,ci_hi,verdict"]
    for k in ['ALL']+kinds:
        for dr in ['BUY','SELL']:
            sub=[r for r in disc if (k=='ALL' or r['kind']==k) and r['direction']==dr]
            vals=[(r['pb'] if dr=='BUY' else r['ps']) for r in sub]
            wins=sum(1 for r in sub if (r['sb'] if dr=='BUY' else r['ss'])=='TARGET')
            s=summ(vals)
            if s['n']<MIN_N: continue
            xo.append(f"{k},{dr},{s['n']},{round(s['mean'],2)},{round(100*wins/s['n'],1)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
    open(os.path.join(od,'EXIT_OPTIMIZATION.csv'),'w').write("\n".join(xo)+"\n")
    # OPPORTUNITY_DENSITY
    od_=["kind,n_total,n_per_day,pct_with_mss,pct_with_disp,pct_econ"]
    for k in kinds:
        s=[r for r in recs if r['kind']==k]
        # econ = |gross 5m| > spread
        econ=sum(1 for r in s if r['gr_5m'] is not None and abs(r['gr_5m'])>26)
        od_.append(f"{k},{len(s)},{len(s)/59.0:.2f},{100*sum(1 for r in s if r['mss'])/len(s):.1f},{100*sum(1 for r in s if r['disp'])/len(s):.1f},{100*econ/len(s):.1f}")
    open(os.path.join(od,'OPPORTUNITY_DENSITY.csv'),'w').write("\n".join(od_)+"\n")
    # COST_STRESS_TEST (best cell)
    cs=["kind,side,horizon,spread_pts,slippage_pts,n,mean_gross,mean_net,pctpos"]
    best=max(allres,key=lambda x:x[3]['mean'] if x[3]['mean'] is not None else -1e9)
    bk,bd,bh,bs,bg=best
    sub=[r for r in disc if r['kind']==bk and r['direction']==bd]
    gs=[r['gr_'+bh] for r in sub if r['gr_'+bh] is not None]
    gsign=[(g if bd=='BUY' else -g) for g in gs]
    for sp in [26,20,15,10,5]:
        for slip in [0,1,2,5]:
            nets=[x-sp-slip for x in gsign]
            cs.append(f"{bk},{bd},{bh},{sp},{slip},{len(nets)},{st.mean(gsign):.2f},{st.mean(nets):.2f},{100*sum(1 for v in nets if v>0)/len(nets):.1f}")
    open(os.path.join(od,'COST_STRESS_TEST.csv'),'w').write("\n".join(cs)+"\n")
    # OOS_RESULTS (best cell per kind)
    oosr=["kind,side,horizon,seg,n,mean_gross,mean_net,pctpos,verdict"]
    for k in kinds:
        fc=[x for x in allres if x[0]==k]
        if not fc: continue
        bc=max(fc,key=lambda x:x[3]['mean'] if x[3]['mean'] is not None else -1e9)
        _,bd,bh,_,_=bc
        for sname,sdata in [('discovery',disc),('validation',val),('oos',oos)]:
            sub=[r for r in sdata if r['kind']==k and r['direction']==bd]
            vals=[(r['nb_'+bh] if bd=='BUY' else r['ns_'+bh]) for r in sub]
            g=[r['gr_'+bh] for r in sub if r['gr_'+bh] is not None]
            s=summ(vals)
            if s['n']<10: continue
            oosr.append(f"{k},{bd},{bh},{sname},{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{verdict(s)}")
    open(os.path.join(od,'OOS_RESULTS.csv'),'w').write("\n".join(oosr)+"\n")
    # FAILED_HYPOTHESES
    fh=["kind,side,horizon,n,mean_net,verdict"]
    for x in allres:
        if x[3]['n']>=MIN_N and x[3]['mean'] is not None and x[3]['mean']<0:
            fh.append(f"{x[0]},{x[1]},{x[2]},{x[3]['n']},{round(x[3]['mean'],2)},{verdict(x[3])}")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(fh)+"\n")
    # STRATEGY_RANKING
    npos=sum(1 for x in allres if verdict(x[3])=='POSITIVE')
    oos_pos=sum(1 for l in oosr[1:] if ',oos,' in l and l.endswith('POSITIVE'))
    rank=["rank,kind,best_side,best_horizon,n,mean_net,verdict"]
    fb=[]
    for k in kinds:
        fc=[x for x in allres if x[0]==k]
        if not fc: continue
        bc=max(fc,key=lambda x:x[3]['mean'] if x[3]['mean'] is not None else -1e9)
        fb.append((k,bc))
    fb.sort(key=lambda x:-(x[1][3]['mean'] if x[1][3]['mean'] is not None else -1e9))
    for i,(k,bc) in enumerate(fb):
        rank.append(f"{i+1},{k},{bc[1]},{bc[2]},{bc[3]['n']},{round(bc[3]['mean'],2)},{verdict(bc[3])}")
    open(os.path.join(od,'STRATEGY_RANKING.csv'),'w').write("\n".join(rank)+"\n")
    # REPORT
    rep=["# M1 Liquidity Hunter - Final Research Report\n",
         f"Capital fixed **10 USD**. events={len(recs)} disc/val/oos={len(disc)}/{len(val)}/{len(oos)}. Spread ~26 pts.",
         f"POSITIVE cells: {npos} | POSITIVE in OOS: {oos_pos}\n",
         "## Ranking\n","\n".join(rank),
         "\n## Decision"]
    if npos>0 and oos_pos>0:
        rep.append("Candidate found - proceed to EA build with independent validation.")
    else:
        rep.append("**No liquidity-hunting cell produced positive expectancy out-of-sample after real cost.** No EA delivered. The 26-pt spread exceeds the predictable post-sweep move at all tested horizons/confirmations.")
    open(os.path.join(od,'FINAL_RESEARCH_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote deliverables to",od,"npos=",npos,"oos_pos=",oos_pos)
if __name__=='__main__':
    main(sys.argv[1],sys.argv[2],sys.argv[3])
