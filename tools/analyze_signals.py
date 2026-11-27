#!/usr/bin/env python3
"""Analyse XTRD SIGNAL ENGINE measurement CSVs. Read-only analysis; no trading."""
import csv, sys, statistics as st
from collections import defaultdict

def load(path):
    with open(path, newline='', encoding='utf-8', errors='ignore') as f:
        return list(csv.DictReader(f))

def fnum(x):
    try: return float(x)
    except: return None

def summarize(vals):
    vals=[v for v in vals if v is not None]
    if not vals: return None
    return dict(n=len(vals), mean=st.mean(vals), median=st.median(vals),
                pos=sum(1 for v in vals if v>0), neg=sum(1 for v in vals if v<0))

def main(sig_path, fol_path, out_path):
    sig=load(sig_path); fol=load(fol_path)
    by_id={r['signal_id']:r for r in sig}
    print(f"signals={len(sig)} followups={len(fol)}")
    if not sig:
        open(out_path,'w').write("# Signal Measurement Report\n\nNo signals were produced.\n"); return
    # join
    rows=[]
    for r in fol:
        s=by_id.get(r['signal_id'])
        if not s: continue
        net=fnum(r['net_pts'])
        rows.append(dict(h=r['horizon'], dir=r['direction'], net=net,
                         mfe=fnum(r['mfe_pts']), mae=fnum(r['mae_pts']),
                         ticks=r['ticks'], hour=(int(s['time_msc'])//3600000)%24,
                         regime=s['regime'], families=s['families'],
                         score=s['score']))
    horizons=['100ms','500ms','1s','3s','5s','10s']
    L=[]
    L.append("# XTRD OMIGA — Signal Measurement Report\n")
    L.append(f"- signals: {len(sig)}  followup rows: {len(fol)}  joined: {len(rows)}\n")
    # overall per horizon
    L.append("## Overall by horizon (net after spread, points)\n")
    L.append("| horizon | n | mean | median | %pos | MFE mean | MAE mean |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    for h in horizons:
        rr=[x for x in rows if x['h']==h]
        s=summarize([x['net'] for x in rr])
        if not s: L.append(f"| {h} | 0 | - | - | - | - | - |"); continue
        mfe=summarize([x['mfe'] for x in rr]); mae=summarize([x['mae'] for x in rr])
        L.append(f"| {h} | {s['n']} | {s['mean']:.2f} | {s['median']:.2f} | {100*s['pos']/s['n']:.1f}% | {mfe['mean']:.2f} | {mae['mean']:.2f} |")
    # by direction
    L.append("\n## By direction\n")
    for d in ['BUY','SELL']:
        L.append(f"### {d}\n")
        L.append("| horizon | n | mean | median | %pos |")
        L.append("|---|---:|---:|---:|---:|")
        for h in horizons:
            rr=[x for x in rows if x['h']==h and x['dir']==d]
            s=summarize([x['net'] for x in rr])
            if not s: L.append(f"| {h} | 0 | - | - | - |"); continue
            L.append(f"| {h} | {s['n']} | {s['mean']:.2f} | {s['median']:.2f} | {100*s['pos']/s['n']:.1f}% |")
    # by family (strategy) at 1s and 10s
    L.append("\n## By strategy family (1s and 10s)\n")
    fams=defaultdict(lambda: defaultdict(list))
    for x in rows:
        for fam in (x['families'] or '').split():
            fams[fam][x['h']].append(x['net'])
    L.append("| family | 1s n | 1s mean | 1s %pos | 10s n | 10s mean | 10s %pos |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    for fam in sorted(fams):
        a=summarize(fams[fam].get('1s')); b=summarize(fams[fam].get('10s'))
        def cell(s):
            return ("0","-","-") if not s else (str(s['n']),f"{s['mean']:.2f}",f"{100*s['pos']/s['n']:.1f}%")
        ca=cell(a); cb=cell(b)
        L.append(f"| {fam} | {ca[0]} | {ca[1]} | {ca[2]} | {cb[0]} | {cb[1]} | {cb[2]} |")
    # by hour at 1s
    L.append("\n## By server hour (1s horizon)\n")
    L.append("| hour | n | mean | %pos |")
    L.append("|---:|---:|---:|---:|")
    for hh in range(24):
        rr=[x for x in rows if x['h']=='1s' and x['hour']==hh]
        s=summarize([x['net'] for x in rr])
        if not s: continue
        L.append(f"| {hh} | {s['n']} | {s['mean']:.2f} | {100*s['pos']/s['n']:.1f}% |")
    # by regime at 1s
    L.append("\n## By regime (1s horizon)\n")
    L.append("| regime | n | mean | %pos |")
    L.append("|---|---:|---:|---:|")
    regs=defaultdict(list)
    for x in rows:
        if x['h']=='1s': regs[x['regime']].append(x['net'])
    for r in sorted(regs):
        s=summarize(regs[r])
        if s: L.append(f"| {r} | {s['n']} | {s['mean']:.2f} | {100*s['pos']/s['n']:.1f}% |")
    open(out_path,'w').write("\n".join(L)+"\n")
    print("wrote",out_path)

if __name__=='__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
