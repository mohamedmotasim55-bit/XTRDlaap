import numpy as np
from harness import load
D={m:load(m) for m in ['m1','m2','m3']}
def bt(d,aT,bS,H,mode):
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
PORTS={
 'A: hr1 pb':[ (1,'pullback') ],
 'B: hr1+15 pb':[ (1,'pullback'),(15,'pullback') ],
 'C: hr1+15pb+3fd':[ (1,'pullback'),(15,'pullback'),(3,'fade') ],
 'D: hr1+15pb+3fd+13fd':[ (1,'pullback'),(15,'pullback'),(3,'fade'),(13,'fade') ],
 'E: hr1+15pb+3fd+13fd+15fd':[ (1,'pullback'),(15,'pullback'),(3,'fade'),(13,'fade'),(15,'fade') ],
}
print("=== محافظ متعددة الساعات ===")
print(f"{'portfolio':<26}{'n':>6}{'m1$':>8}{'m2$':>8}{'m3$':>8}{'tot$':>8}{'DD$':>7}{'كلها+':>7}")
for name,combos in PORTS.items():
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        mo=[]
        for H,mode in combos: mo+=list(bt(D[m],4.0,2.0,H,mode))
        a=np.array(mo); nets.append(a.sum()*0.01 if len(a) else 0); allp.append(a)
    allp=np.concatenate(allp); e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
    allpos=all(n>0 for n in nets)
    print(f"{name:<26}{len(allp):>6}{nets[0]:>8.2f}{nets[1]:>8.2f}{nets[2]:>8.2f}{sum(nets):>8.2f}{abs(dd)*0.01:>7.2f}{'✅' if allpos else '':>7}",flush=True)
