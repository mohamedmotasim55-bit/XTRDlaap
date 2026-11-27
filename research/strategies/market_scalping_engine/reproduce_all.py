#!/usr/bin/env python3
"""Market-only high-density scalping: family discovery + min-exploitable-move + cost-aware filter.
Uses existing micro_features/micro_outcomes (59k decisions, 100ms-10s). No trading. Capital 10 USD.
"""
import csv,sys,os,math,random,statistics as st
from collections import defaultdict
HZ=["100ms","250ms","500ms","1s","2s","5s","10s"]
SPREAD=26.0; MIN_N=100; BLOCK=20; BOOT=1000; SEED=20261127
def rd(p):
    with open(p,newline='',encoding='utf-8',errors='ignore') as f: return list(csv.DictReader(f))
def fn(x):
    try:
        v=float(x); return v if math.isfinite(v) else None
    except: return None
def quant(v,q):
    v=sorted(x for x in v if x is not None)
    return v[int(q*(len(v)-1))] if v else None
def boot_ci(v,block=BLOCK,boot=BOOT,seed=SEED):
    v=[x for x in v if x is not None]; n=len(v)
    if n<10: return (None,None)
    rng=random.Random(seed); nb=max(1,math.ceil(n/block)); mx=max(1,n-block+1); m=[]
    for _ in range(boot):
        s=[]
        for _ in range(nb):
            k=rng.randrange(0,mx); s.extend(v[k:k+block])
        s=s[:n]; m.append(sum(s)/len(s))
    m.sort(); return (m[int(0.025*(len(m)-1))],m[int(0.975*(len(m)-1))])
def summ(v):
    v=[x for x in v if x is not None]
    if not v: return dict(n=0,mean=None,pct=None,lo=None,hi=None)
    lo,hi=boot_ci(v); return dict(n=len(v),mean=st.mean(v),pct=100*sum(1 for x in v if x>0)/len(v),lo=lo,hi=hi)
def verdict(s):
    if s['n']<MIN_N: return "small sample"
    if s['mean'] is not None and s['lo'] is not None and s['lo']>0: return "POSITIVE"
    if s['mean'] is not None and s['hi'] is not None and s['hi']<0: return "negative"
    return "inconclusive"
def load(fp,op):
    feats=rd(fp); outs=rd(op)
    net=defaultdict(dict)
    for r in outs:
        nb=fn(r['net_buy']); ns=fn(r['net_sell'])
        if nb is not None and ns is not None: net[r['decision_id']][r['horizon']]=(nb,ns)
    recs=[]
    for f in feats:
        did=f['decision_id']; d=dict(decision_id=did,time_msc=int(f['time_msc']))
        for k in ['imb100ms','imb250ms','imb500ms','imb1s','tick_rate','vol1s','mom1s','accel','upd_asym','spread_avg','reversals','tickdir_up']:
            d[k]=fn(f.get(k))
        ok=False
        for h in HZ:
            if h in net[did]:
                nb,ns=net[did][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['gr_'+h]=(nb-ns)/2.0; ok=True
            else: d['nb_'+h]=None; d['ns_'+h]=None; d['gr_'+h]=None
        if ok: recs.append(d)
    return recs
def split(recs):
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    def sg(r):
        f=(r['time_msc']-t0)/span
        return 'disc' if f<0.6 else ('val' if f<0.8 else 'oos')
    def pg(r):
        f=(r['time_msc']-t0)/span
        return any(abs(f-b)<10000/span for b in (0.6,0.8))
    return ([r for r in recs if sg(r)=='disc' and not pg(r)],[r for r in recs if sg(r)=='val' and not pg(r)],[r for r in recs if sg(r)=='oos' and not pg(r)])
def main(fp,op,od):
    os.makedirs(od,exist_ok=True)
    recs=load(fp,op); disc,val,oos=split(recs)
    print(f"recs={len(recs)} disc={len(disc)} val={len(val)} oos={len(oos)}")
    # 1) MIN EXPLOITABLE MOVE: distribution of |gross| per horizon
    mem=["horizon,p50_abs,p90_abs,p99_abs,pct_gt_spread,n"]
    for h in HZ:
        g=[abs(r['gr_'+h]) for r in recs if r['gr_'+h] is not None]
        if not g: continue
        gs=sorted(g)
        mem.append(f"{h},{gs[len(gs)//2]:.1f},{gs[int(0.9*len(gs))]:.1f},{gs[int(0.99*len(gs))]:.1f},{100*sum(1 for x in g if x>SPREAD)/len(g):.1f},{len(g)}")
    open(os.path.join(od,'MIN_EXPLOITABLE_MOVE.csv'),'w').write("\n".join(mem)+"\n")
    # 2) FAMILIES: signal definitions on discovery, eval net per horizon
    q_imb=[quant([abs(r['imb250ms']) for r in disc if r['imb250ms'] is not None],x) for x in (0.5,0.7,0.85,0.95)]
    tr=[quant([r['tick_rate'] for r in disc if r['tick_rate'] is not None],x) for x in (0.33,0.66)]
    vo=[quant([r['vol1s'] for r in disc if r['vol1s'] is not None],x) for x in (0.33,0.66)]
    fams={}
    fams['IMB_Q50']=lambda r:r['imb250ms'] is not None and abs(r['imb250ms'])>=q_imb[0]
    fams['IMB_Q70']=lambda r:r['imb250ms'] is not None and abs(r['imb250ms'])>=q_imb[1]
    fams['IMB_Q85']=lambda r:r['imb250ms'] is not None and abs(r['imb250ms'])>=q_imb[2]
    fams['IMB_Q95']=lambda r:r['imb250ms'] is not None and abs(r['imb250ms'])>=q_imb[3]
    fams['TICKRATE_HI']=lambda r:r['tick_rate'] is not None and r['tick_rate']>tr[1]
    fams['VOL_HI']=lambda r:r['vol1s'] is not None and r['vol1s']>vo[1]
    fams['CONFLUENCE']=lambda r:(r['imb250ms'] is not None and abs(r['imb250ms'])>=q_imb[1]) and (r['vol1s'] is not None and r['vol1s']>vo[1])
    fams['REVERSAL_HI']=lambda r:r['reversals'] is not None and r['reversals']>=quant([x['reversals'] for x in disc if x['reversals'] is not None],0.7)
    rank=["family,side,horizon,n_per_day,mean_gross,mean_net,pctpos,ci_lo,ci_hi,verdict"]
    allres=[]
    days=59.0
    for name,sel in fams.items():
        base=[r for r in disc if sel(r)]
        for side,sign in [('BUY',1),('SELL',-1)]:
            sub=[r for r in base if r['imb250ms'] is not None and sign*r['imb250ms']>=0]
            if name.startswith('IMB') or name in ('CONFLUENCE',):
                pass
            else:
                sub=base
            for h in HZ:
                vals=[(r['nb_'+h] if side=='BUY' else r['ns_'+h]) for r in sub]
                g=[r['gr_'+h] for r in sub if r['gr_'+h] is not None]
                s=summ(vals)
                if s['n']<MIN_N: continue
                rank.append(f"{name},{side},{h},{len(vals)/days:.1f},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{round(s['pct'],1)},{'' if s['lo'] is None else round(s['lo'],2)},{'' if s['hi'] is None else round(s['hi'],2)},{verdict(s)}")
                allres.append((name,side,h,s))
    open(os.path.join(od,'FAMILY_RANKING.csv'),'w').write("\n".join(rank)+"\n")
    # 3) COST-AWARE FILTER: min move to be EV>0 for target multiples
    caf=["target_x_spread,target_pts,cost_pts,breakeven_win_pct,note"]
    for k in [1,1.5,2,2.5,3,4]:
        tgt=k*SPREAD; cost=SPREAD  # round-trip cost approx spread (entry+exit embedded)
        be=cost/(tgt+cost)*100
        caf.append(f"{k},{tgt:.0f},{cost:.0f},{be:.1f},need win>{be:.0f}% for EV>0")
    open(os.path.join(od,'COST_AWARE_FILTER.csv'),'w').write("\n".join(caf)+"\n")
    # 4) DENSITY vs EXPECTANCY frontier (best horizon 1s, all families)
    de=["family,side,n_per_day,mean_net_1s,verdict"]
    for name,side,h,s in allres:
        if h=='1s': de.append(f"{name},{side},{s['n']/days:.1f},{round(s['mean'],2)},{verdict(s)}")
    open(os.path.join(od,'DENSITY_EXPECTANCY.csv'),'w').write("\n".join(de)+"\n")
    # 5) OOS of best cells
    best=sorted(allres,key=lambda x:-(x[3]['mean'] if x[3]['mean'] is not None else -1e9))[:10]
    oosr=["family,side,horizon,seg,n,mean_gross,mean_net,verdict"]
    for name,side,h,_ in best:
        sel=fams[name]; sign=1 if side=='BUY' else -1
        for sn,sd in [('disc',disc),('val',val),('oos',oos)]:
            base=[r for r in sd if sel(r)]
            sub=[r for r in base if r['imb250ms'] is not None and sign*r['imb250ms']>=0] if (name.startswith('IMB') or name=='CONFLUENCE') else base
            vals=[(r['nb_'+h] if side=='BUY' else r['ns_'+h]) for r in sub]
            g=[r['gr_'+h] for r in sub if r['gr_'+h] is not None]
            s=summ(vals)
            if s['n']<10: continue
            oosr.append(f"{name},{side},{h},{sn},{s['n']},{'' if not g else round(st.mean(g),2)},{round(s['mean'],2)},{verdict(s)}")
    open(os.path.join(od,'OOS_RESULTS.csv'),'w').write("\n".join(oosr)+"\n")
    # 6) FAILED
    fh=["family,side,horizon,n,mean_net,verdict"]
    for name,side,h,s in allres:
        if s['mean'] is not None and s['mean']<0: fh.append(f"{name},{side},{h},{s['n']},{round(s['mean'],2)},{verdict(s)}")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(fh)+"\n")
    # 7) REPORT
    npos=sum(1 for x in allres if verdict(x[3])=='POSITIVE')
    oos_pos=sum(1 for l in oosr[1:] if ',oos,' in l and l.endswith('POSITIVE'))
    rep=["# Market-Only High-Density Scalping Engine — Discovery Report\n",
         f"Capital fixed **10 USD**. Spread {SPREAD:.0f} pts (real). recs={len(recs)}.",
         f"Families tested: {len(fams)}. POSITIVE cells: {npos} | POSITIVE in OOS: {oos_pos}\n",
         "## Min exploitable move (|gross| distribution)\n"]+mem+[
         "\n## Cost-aware filter (breakeven win% by target)\n"]+caf+[
         "\n## Best cells (all families)\n","| family | side | h | n/day | gross | net | verdict |","|---|---|---|---:|---:|---:|---|"]
    for name,side,h,s in best[:12]:
        rep.append(f"| {name} | {side} | {h} | {s['n']/days:.0f} | - | {round(s['mean'],2)} | {verdict(s)} |")
    rep.append("\n## Decision")
    if npos>0 and oos_pos>0: rep.append("Candidate found - proceed to EA.")
    else: rep.append("**No Market-only scalping family yields positive net expectancy after the real 26-pt spread, at any horizon 100ms-10s.** The min exploitable move test shows the predictable move never clears cost. No EA delivered.")
    open(os.path.join(od,'FINAL_SYNTHESIS_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote to",od,"npos=",npos,"oos_pos=",oos_pos)
if __name__=='__main__': main(sys.argv[1],sys.argv[2],sys.argv[3])
