#!/usr/bin/env python3
"""Sub-second microstructure discovery analysis. Read-only. No trading.
Inputs: micro_features.csv, micro_outcomes.csv
Outputs: TICK_CLASSIFICATION_AUDIT.csv, MICROSTRUCTURE_FEATURES.csv, FEATURE_PREDICTABILITY.csv,
         OOS_RESULTS.csv, COST_SENSITIVITY.csv, FAILED_HYPOTHESES.csv, MICROSTRUCTURE_DISCOVERY_REPORT.md
Capital fixed = 10 USD.
"""
import csv, sys, os, math, random, statistics as st
from collections import defaultdict

HZ = ["100ms","250ms","500ms","1s","2s","5s","10s"]
FEATS = ["imb100ms","imb250ms","imb500ms","imb1s","imb2s","imb5s","imb10s",
         "tickdir_up","tickdir_dn","tickdir_zero","bid_upd_rate","ask_upd_rate","upd_asym",
         "tick_rate","iat_ms","reversals","mom1s","mom5s","accel","vol1s","spread_avg","spread_chg"]
MIN_N = 200
BLOCK = 20; BOOT = 1000; SEED = 20261127
SPREAD = 26.0

def rd(p):
    with open(p,newline='',encoding='utf-8',errors='ignore') as f: return list(csv.DictReader(f))
def fn(x):
    try:
        v=float(x); return v if math.isfinite(v) else None
    except: return None
def entropy(counts):
    n=sum(counts)
    if n<=0: return 0.0
    return -sum((c/n)*math.log2(c/n) for c in counts if c>0)
def quant_bins(vals,k=5):
    v=sorted(vals)
    if not v: return []
    return [v[int(i*len(v)/k)] for i in range(1,k)]
def bin_of(x,cuts):
    i=0
    for c in cuts:
        if x>c: i+=1
        else: break
    return i
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

def main(feat_p,out_p,od):
    os.makedirs(od,exist_ok=True)
    feats=rd(feat_p); outs=rd(out_p)
    fby={r['decision_id']:r for r in feats}
    net=defaultdict(dict)
    for r in outs:
        nb=fn(r['net_buy']); ns=fn(r['net_sell'])
        if nb is not None and ns is not None: net[r['decision_id']][r['horizon']]=(nb,ns)
    recs=[]
    for did,f in fby.items():
        d=dict(decision_id=did,time_msc=int(f['time_msc']),hour=int(f['hour']),weekday=int(f['weekday']))
        for k in FEATS: d[k]=fn(f[k])
        ok=False
        for h in HZ:
            if h in net[did]:
                nb,ns=net[did][h]; d['nb_'+h]=nb; d['ns_'+h]=ns; d['up_'+h]=1 if nb>ns else 0; ok=True
            else:
                d['nb_'+h]=None; d['ns_'+h]=None; d['up_'+h]=None
        if ok: recs.append(d)
    print(f"decisions={len(feats)} with-labels={len(recs)}")
    recs.sort(key=lambda r:r['time_msc'])
    t0=recs[0]['time_msc']; t1=recs[-1]['time_msc']; span=t1-t0 if t1>t0 else 1
    EMB=10000
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

    # TICK CLASSIFICATION AUDIT: tick-rule direction distribution + does tick-rule predict next move
    tca=["rule,metric,value"]
    for k in ["tickdir_up","tickdir_dn","tickdir_zero"]:
        v=[r[k] for r in recs if r[k] is not None]
        if v: tca.append(f"tick_rule_1s,mean_{k},{st.mean(v):.4f}")
    # P(up) conditional on tickdir_up tercile
    for h in ["500ms","1s","5s"]:
        sub=[r for r in recs if r['tickdir_up'] is not None and r['up_'+h] is not None]
        if len(sub)<50: continue
        base=sum(r['up_'+h] for r in sub)/len(sub)
        cuts=quant_bins([r['tickdir_up'] for r in sub],3)
        binc=defaultdict(list)
        for r in sub: binc[bin_of(r['tickdir_up'],cuts)].append(r['up_'+h])
        for b in sorted(binc):
            ls=binc[b]; tca.append(f"tick_rule_up_tercile_{h},bin{b}_P_up,{sum(ls)/len(ls):.4f}")
        tca.append(f"tick_rule_up_tercile_{h},base_P_up,{base:.4f}")
    open(os.path.join(od,'TICK_CLASSIFICATION_AUDIT.csv'),'w').write("\n".join(tca)+"\n")

    # MICROSTRUCTURE_FEATURES summary
    mf=["feature,mean,median,p05,p95,std"]
    for k in FEATS:
        v=[r[k] for r in recs if r[k] is not None]
        if v:
            vs=sorted(v); mf.append(f"{k},{st.mean(v):.4f},{st.median(v):.4f},{vs[int(0.05*len(vs))]:.4f},{vs[int(0.95*len(vs))]:.4f},{st.pstdev(v):.4f}")
    open(os.path.join(od,'MICROSTRUCTURE_FEATURES.csv'),'w').write("\n".join(mf)+"\n")

    # FEATURE_PREDICTABILITY: IG per feature per horizon (discovery)
    fp=["feature,horizon,n,H_label,IG"]
    for k in FEATS:
        vals=[r[k] for r in disc if r[k] is not None]
        if len(vals)<50: continue
        cuts=quant_bins(vals,5)
        for h in HZ:
            sub=[r for r in disc if r[k] is not None and r['up_'+h] is not None]
            if len(sub)<50: continue
            labels=[r['up_'+h] for r in sub]
            Hl=entropy([sum(labels),len(labels)-sum(labels)])
            binc=defaultdict(list)
            for r in sub: binc[bin_of(r[k],cuts)].append(r['up_'+h])
            Hc=0.0
            for b,ls in binc.items(): Hc+=(len(ls)/len(sub))*entropy([sum(ls),len(ls)-sum(ls)])
            fp.append(f"{k},{h},{len(sub)},{Hl:.4f},{Hl-Hc:.5f}")
    open(os.path.join(od,'FEATURE_PREDICTABILITY.csv'),'w').write("\n".join(fp)+"\n")

    # OOS_RESULTS: top features by IG at 1s, tested in each segment
    rows=[l.split(',') for l in fp[1:] if l.split(',')[1]=='1s']
    rows.sort(key=lambda r:-float(r[4]))
    oosr=["feature,horizon,seg,n,p_up,base,lift,mean_net_buy,mean_net_sell,verdict"]
    for r in rows[:8]:
        k=r[0]; vals=[x[k] for x in disc if x[k] is not None]; cuts=quant_bins(vals,5)
        for sname,sdata in [('discovery',disc),('validation',val),('oos',oos)]:
            sub=[x for x in sdata if x[k] is not None and x['up_1s'] is not None]
            if len(sub)<50: continue
            base=sum(x['up_1s'] for x in sub)/len(sub)
            binc=defaultdict(list)
            for x in sub: binc[bin_of(x[k],cuts)].append(x['up_1s'])
            bb=max(binc,key=lambda b:abs(sum(binc[b])/len(binc[b])-base))
            ls=binc[bb]; p=sum(ls)/len(ls)
            cell=[x for x in sub if bin_of(x[k],cuts)==bb]
            nbs=[x['nb_1s'] for x in cell if x['nb_1s'] is not None]
            nss=[x['ns_1s'] for x in cell if x['ns_1s'] is not None]
            v="no edge"
            if p>0.55 and len(ls)>=MIN_N: v="buy candidate"
            elif p<0.45 and len(ls)>=MIN_N: v="sell candidate"
            oosr.append(f"{k},1s,{sname},{len(ls)},{p:.4f},{base:.4f},{p-base:+.4f},"
                        f"{(st.mean(nbs) if nbs else 0):.2f},{(st.mean(nss) if nss else 0):.2f},{v}")
    open(os.path.join(od,'OOS_RESULTS.csv'),'w').write("\n".join(oosr)+"\n")

    # COST_SENSITIVITY: gross-to-net under spread scenarios for the best feature cells (1s)
    cs=["feature,bin,horizon,spread_pts,slippage_pts,n,mean_gross_pts,mean_net_pts,pctpos"]
    for r in rows[:4]:
        k=r[0]; vals=[x[k] for x in disc if x[k] is not None]; cuts=quant_bins(vals,5)
        for b in [0,4]:
            cell=[x for x in recs if x[k] is not None and x['nb_1s'] is not None and bin_of(x[k],cuts)==b]
            if len(cell)<20: continue
            gross=[(x['nb_1s']-x['ns_1s'])/2.0 for x in cell]  # mid move
            for sp in [26,20,15,10]:
                for slip in [0,1,2,5]:
                    nets=[g-sp-slip for g in gross]
                    cs.append(f"{k},{b},1s,{sp},{slip},{len(nets)},{st.mean(gross):.2f},{st.mean(nets):.2f},{100*sum(1 for v in nets if v>0)/len(nets):.1f}")
    open(os.path.join(od,'COST_SENSITIVITY.csv'),'w').write("\n".join(cs)+"\n")

    # FAILED_HYPOTHESES
    fh=["feature,horizon,IG,classification"]
    for r in rows:
        if float(r[4])<0.002: fh.append(f"{r[0]},1s,{r[4]},No Predictive Information")
    if len(fh)==1: fh.append("(none),-,-,-")
    open(os.path.join(od,'FAILED_HYPOTHESES.csv'),'w').write("\n".join(fh)+"\n")

    # REPORT
    top=rows[:8]
    rep=["# Sub-Second Microstructure Discovery\n",
         f"Capital fixed **10 USD**. Decisions: {len(recs)} (60s sampling, 59 days). Split {len(disc)}/{len(val)}/{len(oos)} (embargo 10s).\n",
         "## Top features by information gain (1s, discovery)\n","| feature | IG |","|---|---|"]
    for r in top: rep.append(f"| {r[0]} | {float(r[4]):.5f} |")
    rep.append("\n## Tick classification audit")
    rep.append("\n".join(tca[:12]))
    rep.append("\n## OOS stability (top feature cells)")
    rep.append("\n".join([l for l in oosr[1:] if ',oos,' in l][:10]))
    rep.append("\n## Verdict rules")
    rep.append("- Confirmed only if OOS lift stable AND net>0 after cost AND beats random after multiple-testing correction.")
    open(os.path.join(od,'MICROSTRUCTURE_DISCOVERY_REPORT.md'),'w').write("\n".join(rep)+"\n")
    print("wrote deliverables to",od)

if __name__=='__main__':
    main(sys.argv[1],sys.argv[2],sys.argv[3])
