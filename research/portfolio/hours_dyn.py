import numpy as np
from harness import load
D={m:load(m) for m in ['m1','m2','m3']}
def bt(d,aT,bS,H,mode='pullback'):
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
        else: # fade
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
print("=== مسح 24 ساعة — 4×ATR/2×ATR ===")
print(f"{'hr':>3}{'mode':>9}{'n':>6}{'WR%':>6}{'m1$':>7}{'m2$':>7}{'m3$':>7}{'tot$':>8}{'كلها+':>7}")
good=[]
for mode in ['pullback','fade']:
    for H in range(24):
        nets=[]; allp=[]
        for m in ['m1','m2','m3']:
            a=bt(D[m],4.0,2.0,H,mode); nets.append(a.sum()*0.01 if len(a) else 0); allp.append(a)
        allp=np.concatenate(allp)
        if len(allp)<10: continue
        tot=sum(nets); allpos=all(n>0 for n in nets)
        if tot>0:
            print(f"{H:>3}{mode:>9}{len(allp):>6}{(allp>0).mean()*100:>6.1f}{nets[0]:>7.2f}{nets[1]:>7.2f}{nets[2]:>7.2f}{tot:>8.2f}{'✅' if allpos else '':>7}")
            good.append((H,mode,tot,allpos,len(allp)))
print(f"\nساعات موجبة: {len(good)}")
print(f"مجموع الساعات الموجبة: {sum(g[2] for g in good):.2f}$")
print(f"مجموع الصفقات: {sum(g[4] for g in good)}")
