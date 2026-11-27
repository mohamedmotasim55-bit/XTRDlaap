import numpy as np, json
from harness import load
D={m:load(m) for m in ['m1','m2','m3']}
def bt(d,aT,bS,H,mode,trail):
    bcl,acl,bhi,blo,ahi,alo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['vol'],d['volavg'],d['nb']
    atr=d['rngavg']; hr=((d['t']%86400)//3600); pnls=[]; i=1500
    while i<nb-1:
        if int(hr[i])!=H: i+=1; continue
        if vol[i-1]<1.0*volavg[i-1]: i+=1; continue
        A=atr[i-1]
        if not (A>0): i+=1; continue
        hh=bhi[i-31:i-1].max(); ll=blo[i-31:i-1].min(); tr=bcl[i-1]-bcl[i-1-1440]
        dr=0
        if mode=='pullback':
            if bcl[i-1]>hh+20 and tr<0: dr=-1
            elif bcl[i-1]<ll-20 and tr>0: dr=1
        else:
            if bcl[i-1]>hh+20: dr=-1
            elif bcl[i-1]<ll-20: dr=1
        if dr==0: i+=1; continue
        tgt=aT*A; stp=bS*A; trl=trail*A
        ent=acl[i-1] if dr>0 else bcl[i-1]; k=min(i+120,nb-1); pnl=None; mfe=0.0
        for j in range(i,k+1):
            fav=(bcl[j]-ent) if dr>0 else (ent-acl[j])
            if fav>mfe: mfe=fav
            if dr>0:
                if blo[j]<=ent-stp: pnl=-stp; break
                if tgt and bhi[j]>=ent+tgt: pnl=tgt; break
            else:
                if ahi[j]>=ent+stp: pnl=-stp; break
                if tgt and alo[j]<=ent-tgt: pnl=tgt; break
            if trl and mfe>=trl and (mfe-fav)>=trl*0.4: pnl=fav; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        pnls.append(pnl); i=k+1
    a=np.array(pnls); return a
# discover best per hour on m1
best={}
for H in range(24):
    bb=None
    for mode in ['pullback','fade']:
        for aT,bS in [(2,1),(3,1.5),(4,2),(6,2)]:
            for trl in [0,1.5,2.5]:
                a=bt(D['m1'],aT,bS,H,mode,trl)
                if len(a)<15: continue
                net=a.sum()
                if bb is None or net>bb[0]: bb=(net,mode,aT,bS,trl,len(a))
    if bb: best[H]=bb
print("=== شخصيات الساعات (اكتُشفت على m1) ===")
print(f"{'hr':>3}{'mode':>9}{'aT':>4}{'bS':>4}{'trl':>5}{'m1$':>8}{'m2$':>8}{'m3$':>8}{'OOS$':>8}{'OOS+':>5}")
tot_oos=0; pos_hours=0; tot_n=0
for H,(net,mode,aT,bS,trl,n) in sorted(best.items()):
    m2=bt(D['m2'],aT,bS,H,mode,trl); m3=bt(D['m3'],aT,bS,H,mode,trl)
    oos=(m2.sum()+m3.sum())*0.01
    tot_oos+=oos; tot_n+=len(m2)+len(m3)
    if oos>0: pos_hours+=1
    print(f"{H:>3}{mode:>9}{aT:>4}{bS:>4}{trl:>5}{net*0.01:>8.2f}{m2.sum()*0.01:>8.2f}{m3.sum()*0.01:>8.2f}{oos:>8.2f}{'✅' if oos>0 else '❌':>5}",flush=True)
print(f"\n=== خارج العينة (m2+m3): {pos_hours}/24 ساعة موجبة | إجمالي ${tot_oos:.2f} | صفقات {tot_n} ===")
json.dump({str(k):v for k,v in best.items()},open('personality.json','w'),indent=1)
