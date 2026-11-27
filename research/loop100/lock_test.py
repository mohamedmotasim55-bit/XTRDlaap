import numpy as np
from harness import load,signals,Eng
def execute_lock(d,e,BE=0,TR=0):
    bcl,acl,bhi,blo,ahi,alo,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['nb']
    sig=signals(d,e); pnls=[]; last=-10**9
    for i,dr in sig:
        if i<=last: continue
        ent=acl[i-1] if dr>0 else bcl[i-1]
        k=min(i+e.hold,nb-1); pnl=None; mfe=0.0
        for j in range(i,k+1):
            fav=(bcl[j]-ent) if dr>0 else (ent-acl[j])
            if fav>mfe: mfe=fav
            if dr>0:
                if blo[j]<=ent-e.stop: pnl=-e.stop; break
                if BE and mfe>=BE and (mfe-fav)>=TR: pnl=fav; break
            else:
                if ahi[j]>=ent+e.stop: pnl=-e.stop; break
                if BE and mfe>=BE and (mfe-fav)>=TR: pnl=fav; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        pnls.append(pnl); last=k
    a=np.array(pnls); return a
D={m:load(m) for m in ['m1','m2','m3']}
print("=== TREND_PULLBACK + قفل الربح الوقائي ===")
print(f"{'BE/TR':>10}{'n':>6}{'WR%':>6}{'net$':>8}{'DD$':>7}{'m1':>7}{'m2':>7}{'m3':>7}")
for BE,TR in [(0,0),(20,10),(30,15),(30,10),(50,20),(40,20)]:
    e=Eng('TREND_PULLBACK',80,45,0,(1,))
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        a=execute_lock(D[m],e,BE,TR); nets.append(a.sum()*0.01); allp.append(a)
    allp=np.concatenate(allp); e2=np.cumsum(allp); dd=(e2-np.maximum.accumulate(e2)).min()
    print(f"{str(BE)+'/'+str(TR):>10}{len(allp):>6}{(allp>0).mean()*100:>6.1f}{allp.sum()*0.01:>8.2f}{abs(dd)*0.01:>7.2f}{nets[0]:>7.2f}{nets[1]:>7.2f}{nets[2]:>7.2f}",flush=True)
