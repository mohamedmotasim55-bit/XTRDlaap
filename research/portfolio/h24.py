import numpy as np
from harness import load
D={m:load(m) for m in ['m1','m2','m3']}
def bt(d,aT,bS,mode):
    bcl,acl,bhi,blo,ahi,alo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['vol'],d['volavg'],d['nb']
    atr=d['rngavg']; pnls=[]; i=1500
    while i<nb-1:
        if vol[i-1]<1.0*volavg[i-1]: i+=1; continue
        A=atr[i-1]
        if not (A>0): i+=1; continue
        hh=bhi[i-31:i-1].max(); ll=blo[i-31:i-1].min(); tr=bcl[i-1]-bcl[i-1-1440]
        dr=0
        if mode=='pullback':
            if bcl[i-1]>hh+20 and tr<0: dr=-1
            elif bcl[i-1]<ll-20 and tr>0: dr=1
        elif mode=='fade':
            if bcl[i-1]>hh+20: dr=-1
            elif bcl[i-1]<ll-20: dr=1
        else: # both: try pullback first then fade
            if bcl[i-1]>hh+20 and tr<0: dr=-1
            elif bcl[i-1]<ll-20 and tr>0: dr=1
            elif bcl[i-1]>hh+20: dr=-1
            elif bcl[i-1]<ll-20: dr=1
        if dr==0: i+=1; continue
        tgt=aT*A; stp=bS*A
        ent=acl[i-1] if dr>0 else bcl[i-1]; k=min(i+120,nb-1); pnl=None
        for j in range(i,k+1):
            if dr>0:
                if blo[j]<=ent-stp: pnl=-stp; break
                if tgt and bhi[j]>=ent+tgt: pnl=tgt; break
            else:
                if ahi[j]>=ent+stp: pnl=-stp; break
                if tgt and alo[j]<=ent-tgt: pnl=tgt; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        pnls.append(pnl); i=k+1
    a=np.array(pnls); return a
print("=== 24/7 متواصل — بلا فلتر ساعات — 4×ATR/2×ATR ===")
print(f"{'mode':>10}{'n':>7}{'n/يوم':>7}{'WR%':>6}{'m1$':>8}{'m2$':>8}{'m3$':>8}{'tot$':>9}{'DD$':>7}{'كلها+':>7}")
for mode in ['pullback','fade','both']:
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        a=bt(D[m],4.0,2.0,mode); nets.append(a.sum()*0.01 if len(a) else 0); allp.append(a)
    allp=np.concatenate(allp); e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
    allpos=all(n>0 for n in nets)
    print(f"{mode:>10}{len(allp):>7}{len(allp)/66:>7.0f}{(allp>0).mean()*100:>6.1f}{nets[0]:>8.2f}{nets[1]:>8.2f}{nets[2]:>8.2f}{sum(nets):>9.2f}{abs(dd)*0.01:>7.2f}{'✅' if allpos else '':>7}",flush=True)
