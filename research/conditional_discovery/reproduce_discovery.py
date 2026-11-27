#!/usr/bin/env python3
"""Conditional market predictability discovery. Read-only. No trading.
Inputs : cond_features.csv, cond_outcomes.csv
Outputs: CONDITIONAL_FEATURES.csv, FEATURE_INFORMATION_GAIN.csv, FEATURE_INTERACTIONS.csv,
         DIRECTIONAL_PREDICTABILITY.csv, FIRST_PASSAGE_ANALYSIS.csv, CONDITIONAL_EDGE_RESULTS.csv,
         OUT_OF_SAMPLE_DISCOVERY.csv, FAILED_HYPOTHESES.csv, CONDITIONAL_DISCOVERY_REPORT.md
Capital fixed = 10 USD. No tuning to positive.
"""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict

HZ = ["1s","3s","5s","10s","30s","60s","120s","300s","5m","10m","15m","30m"]
MIN_N = 200
BLOCK = 20; BOOT = 1000; SEED = 20261127
FEATS = ["v100ms","v250ms","v500ms","v1s","v3s","v5s","v10s","accel",
         "range60_pts","atr60_pts","atr300_pts","comp_ratio","efficiency","reversals",
         "dist_high","dist_low","spread_avg60","spread_change","bid_upd_rate","ask_upd_rate","sync","z"]

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

def entropy(counts):
    n=sum(counts)
    if n<=0: return 0.0
    return -sum((c/n)*math.log2(c/n) for c in counts if c>0)

def quant_bins(vals, k=5):
    v=sorted(vals)
    if not v: return []
    return [v[int(i*len(v)/k)] for i in range(1,k)]

def bin_of(x, cuts):
    i=0
    for c in cuts:
        if x>c: i+=1
        else: break
    return i

def main(feat_p, out_p, od):
    os.makedirs(od,exist_ok=True)
    feats=rd(feat_p); outs=rd(out_p)
    fby={r['decision_id']:r for r in feats}
    net=defaultdict(dict); first=defaultdict(dict)
    for r in outs:
        did=r['decision_id']
        if r['kind'] in ('NET_SHORT','NET_LONG'):
            nb=fn(r['net_buy']); ns=fn(r['net_sell'])
            if nb is not None and ns is not None: net[did][r['key']]=(nb,ns)
        elif r['kind']=='FIRST':
            first[did][r['key']]=(r['first_side'], fn(r['up_time_s']), fn(r['down_time_s']))
    recs=[]
    for did,f in fby.items():
        d=dict(decision_id=did, time_msc=int(f['time_msc']), hour=int(f['hour']), weekday=int(f['weekday']), spread=fn(f['spread_pts']))
        for k in FEATS: d[k]=fn(f[k])
        ok=False
        for h in HZ:
            if h in net[did]:
                nb,ns=net[did][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['up_'+h]=1 if nb>ns else 0; ok=True
            else:
                d['nb_'+h]=None; d['ns_'+h]=None; d['up_'+h]=None
        for lvl in ['1.0x','1.5x','2.0x','3.0x']:
            if lvl in first[did]:
                side,ut,dt=first[did][lvl]; d['fs_'+lvl]=side; d['ut_'+lvl]=ut; d['dt_'+lvl]=dt
            else: d['fs_'+lvl]=None
        if ok: recs.append(d)
    print(f"decisions={len(feats)} with-labels={len(recs)}")
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    EMB=1800*1000
    def segf(r): 
        f=(r['time_msc']-t0)/span
        return 'discovery' if f<0.6 else ('validation' if f<0.8 else 'oos')
    def purged(r):
        f=(r['time_msc']-t0)/span
        return any(abs(f-b)<EMB/span for b in (0.6,0.8))
    disc=[r for r in recs if segf(r)=='discovery' and not purged(r)]
    val=[r for r in recs if segf(r)=='validation' and not purged(r)]
    oos=[r for r in recs if segf(r)=='oos' and not purged(r)]
    print(f"disc={len(disc)} val={len(val)} oos={len(oos)}")

    cf=["feature,mean,median,p05,p95,std"]
    for k in FEATS:
        v=[r[k] for r in recs if r[k] is not None]
        if v:
            vs=sorted(v); cf.append(f"{k},{st.mean(v):.4f},{st.median(v):.4f},{vs[int(0.05*len(vs))]:.4f},{vs[int(0.95*len(vs))]:.4f},{st.pstdev(v):.4f}")
    open(os.path.join(od,'CONDITIONAL_FEATURES.csv'),'w').write("\n".join(cf)+"\n")

    ig=["feature,horizon,n,H_label,H_given_feature,information_gain,mutual_info"]
    for k in FEATS:
        vals=[r[k] for r in disc if r[k] is not None]
        if len(vals)<50: continue
        cuts=quant_bins(vals,5)
        for h in HZ:
            sub=[r for r in disc if r[k] is not None and r['up_'+h] is not None]
            if len(sub)<50: continue
            labels=[r['up_'+h] for r in sub]
            Hl=entropy([sum(labels), len(labels)-sum(labels)])
            binc=defaultdict(list)
            for r in sub: binc[bin_of(r[k],cuts)].append(r['up_'+h])
            Hc=0.0
            for b,ls in binc.items(): Hc += (len(ls)/len(sub))*entropy([sum(ls),len(ls)-sum(ls)])
            ig.append(f"{k},{h},{len(sub)},{Hl:.4f},{Hc:.4f},{Hl-Hc:.5f},{Hl-Hc:.5f}")
    open(os.path.join(od,'FEATURE_INFORMATION_GAIN.csv'),'w').write("\n".join(ig)+"\n")

    dp=["feature,bin,bin_lo,bin_hi,n,p_up,base_p_up,lift"]
    for k in FEATS:
        vals=[r[k] for r in disc if r[k] is not None]
        if len(vals)<50: continue
        cuts=quant_bins(vals,5)
        sub=[r for r in disc if r[k] is not None and r['up_60s'] is not None]
        if len(sub)<50: continue
        base=sum(r['up_60s'] for r in sub)/len(sub)
        binc=defaultdict(list)
        for r in sub: binc[bin_of(r[k],cuts)].append(r['up_60s'])
        for b in sorted(binc):
            ls=binc[b]; p=sum(ls)/len(ls)
            lo=cuts[b-1] if b>0 else min(vals); hi=cuts[b] if b<len(cuts) else max(vals)
            dp.append(f"{k},{b},{lo:.4f},{hi:.4f},{len(ls)},{p:.4f},{base:.4f},{p-base:+.4f}")
    open(os.path.join(od,'DIRECTIONAL_PREDICTABILITY.csv'),'w').write("\n".join(dp)+"\n")

    fp=["level,n,p_up_first,p_down_first,p_none,mean_up_time_s,mean_down_time_s"]
    for lvl in ['1.0x','1.5x','2.0x','3.0x']:
        sides=[r['fs_'+lvl] for r in disc if r['fs_'+lvl] is not None]
        if not sides: continue
        up=sum(1 for s in sides if s=='UP'); dn=sum(1 for s in sides if s=='DOWN'); no=sum(1 for s in sides if s=='NONE')
        ut=[r['ut_'+lvl] for r in disc if r['ut_'+lvl] is not None]; dt=[r['dt_'+lvl] for r in disc if r['dt_'+lvl] is not None]
        fp.append(f"{lvl},{len(sides)},{up/len(sides):.4f},{dn/len(sides):.4f},{no/len(sides):.4f},{(st.mean(ut) if ut else 0):.2f},{(st.mean(dt) if dt else 0):.2f}")
    open(os.path.join(od,'FIRST_PASSAGE_ANALYSIS.csv'),'w').write("\n".join(fp)+"\n")

    ig_rows=[l.split(',') for l in ig[1:] if l.split(',')[1]=='60s']
    ig_rows.sort(key=lambda r:-float(r[5]))
    ce=["feature,bin,horizon,seg,n,p_up,mean_net_buy,mean_net_sell,ci_lo,ci_hi,edge_verdict"]
    for r in ig_rows[:6]:
        k=r[0]; vals=[x[k] for x in disc if x[k] is not None]; cuts=quant_bins(vals,5)
        for seg_name,seg_data in [('discovery',disc),('validation',val),('oos',oos)]:
            for b in [0,4]:
                sub=[x for x in seg_data if x[k] is not None and x['up_60s'] is not None and bin_of(x[k],cuts)==b]
                if len(sub)<10: continue
                p=sum(x['up_60s'] for x in sub)/len(sub)
                nbs=[x['nb_60s'] for x in sub if x['nb_60s'] is not None]; nss=[x['ns_60s'] for x in sub if x['ns_60s'] is not None]
                lo,hi=boot_ci(nbs)
                ver="no edge"
                if p>0.55 and lo is not None and lo>0: ver="buy candidate"
                elif p<0.45 and hi is not None and hi<0: ver="sell candidate"
                ce.append(f"{k},{b},60s,{seg_name},{len(sub)},{p:.3f},{(st.mean(nbs) if nbs else 0):.2f},{(st.mean(nss) if nss else 0):.2f},{'' if lo is None else round(lo,2)},{'' if hi is None else round(hi,2)},{ver}")
    open(os.path.join(od,'CONDITIONAL_EDGE_RESULTS.csv'),'w').write("\n".join(ce)+"\n")

    oosr=["feature,horizon,seg,p_up,n,lift"]
    for r in ig_rows[:8]:
        k=r[0]; vals=[x[k] for x in disc if x[k] is not None]; cuts=quant_bins(vals,5)
        for seg_name,seg_data in [('discovery',disc),('validation',val),('oos',oos)]:
            sub=[x for x in seg_data if x[k] is not None and x['up_60s'] is not None]
            if len(sub)<10: continue
            base=sum(x['up_60s'] for x in sub)/len(sub)
            binc=defaultdict(list)
            for x in sub: binc[bin_of(x[k],cuts)].append(x['up_60s'])
            bb=max(binc,key=lambda b:abs(sum(binc[b])/len(binc[b])-base))
            p=sum(binc[bb])/len(binc[bb])
            oosr.append(f"{k},60s,{seg_name},{p:.4f},{len(binc[bb])},{p-base:+.4f}")
    open(os.path.join(od,'OUT_OF_SAMPLE_DISCOVERY.csv'),'w').write("\n".join(oosr)+"\n")

    fi=["feat1,feat2,bin1,bin2,n,p_up,lift"]
    for f1,f2 in [('v3s','atr60_pts'),('efficiency','atr60_pts'),('comp_ratio','v3s'),('spread_change','v3s')]:
        v1=[x[f1] for x in disc if x[f1] is not None]; v2=[x[f2] for x in disc if x[f2] is not None]
        if len(v1)<50 or len(v2)<50: continue
        c1=quant_bins(v1,3); c2=quant_bins(v2,3)
        sub=[x for x in disc if x[f1] is not None and x[f2] is not None and x['up_60s'] is not None]
        base=sum(x['up_60s'] for x in sub)/len(sub) if sub else 0
        cell=defaultdict(list)
        for x in sub: cell[(bin_of(x[f1],c1),bin_of(x[f2],c2))].append(x['up_60s'])
        for (b1,b2),ls in sorted(cell.items()):
            if len(ls)>=50: fi.append(f"{f1},{f2},{b1},{b2},{len(ls)},{sum(ls)/len(ls):.4f},{sum(ls)/len(ls)-base:+.4f}")
    open(os.path.join(od,'FEATURE_INTERACTIONS.csv'),'w').write("\n".join(fi)+"\n")

    failed=["hypothesis,detail,result"]
    for r in ig_rows:
        if float(r[5])<0.002: failed.append(f"{r[0]}@60s,IG={r[5]},No Predictive Information")
    if len(failed)==1: failed.append("(none)","-","-")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(failed)+"\n")

    rep=["# Conditional Market Predictability Discovery\n",
         f"Capital fixed **10 USD**. Decisions: {len(recs)} (120s sampling, 59 days). Split disc/val/oos = {len(disc)}/{len(val)}/{len(oos)} (embargo 1800s).\n",
         "## Top features by information gain (60s, discovery set)\n","| feature | IG |","|---|---|"]
    for r in ig_rows[:8]: rep.append(f"| {r[0]} | {float(r[5]):.5f} |")
    rep.append("\n## First passage (discovery)\n"); rep.append("\n".join(fp))
    rep.append("\n## Classification rules")
    rep.append("- IG ~ 0 => No Predictive Information. Any lift must survive OOS to be Confirmed.")
    rep.append("- Confirmed Predictive Information / Statistical Association Only / No Predictive Information / Inconclusive.")
    open(os.path.join(od,'CONDITIONAL_DISCOVERY_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote all deliverables to", od)

if __name__=='__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
