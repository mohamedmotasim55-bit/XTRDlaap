import numpy as np
def prep(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    A=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=B[last]; As=A[last]; nb=len(Bs)//60; N=nb*60; ix=np.arange(0,N,60)
    bcl=Bs[59:N:60]; acl=As[59:N:60]; bhi=np.maximum.reduceat(Bs[:N],ix); blo=np.minimum.reduceat(Bs[:N],ix)
    ahi=np.maximum.reduceat(As[:N],ix); alo=np.minimum.reduceat(As[:N],ix)
    vol=np.add.reduceat(cnt[:N],ix); volavg=np.convolve(vol,np.ones(60)/60,'full')[:nb]
    return dict(bcl=bcl,acl=acl,bhi=bhi,blo=blo,ahi=ahi,alo=alo,vol=vol,volavg=volavg,nb=nb)
D={m:prep(m) for m in ['m1','m2','m3']}
def run(mode,TGT,S,HOLD,PULSE=1.5,M1=1,M5=5,COOL=5):
    res=[]
    for m in ['m1','m2','m3']:
        d=D[m]; bcl,acl,bhi,blo,ahi,alo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['vol'],d['volavg'],d['nb']
        pnls=[]; i=max(M5,60)+1
        while i<nb-1:
            if not (vol[i-1]>PULSE*volavg[i-1]): i+=1; continue
            t1=bcl[i-1]-bcl[i-1-M1]; t5=bcl[i-1]-bcl[i-1-M5]
            if mode=='mom':
                if t1>0 and t5>0: dr=1
                elif t1<0 and t5<0: dr=-1
                else: i+=1; continue
            else:
                if t5>0 and t1<0: dr=1
                elif t5<0 and t1>0: dr=-1
                else: i+=1; continue
            ent=acl[i] if dr>0 else bcl[i]
            k=min(i+HOLD,nb)-1; pnl=None
            for j in range(i,k+1):
                if dr>0:
                    if blo[j]<=ent-S: pnl=-S; break
                    if bhi[j]>=ent+TGT: pnl=TGT; break
                else:
                    if ahi[j]>=ent+S: pnl=-S; break
                    if alo[j]<=ent-TGT: pnl=TGT; break
            if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
            pnls.append(pnl); i=k+1+COOL
        res.append(np.array(pnls))
    allp=np.concatenate(res)
    if len(allp)==0: return None
    e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
    return len(allp),(allp>0).mean()*100,allp.sum(),allp.mean(),dd,res
print("=== نبض + اتجاه 1د/5د ===")
print(f"{'mode':>5}{'TGT':>5}{'S':>5}{'H':>4}{'PUL':>5}{'n':>6}{'WR':>6}{'EV':>7}{'net':>8}{'DD$':>6}{'m1':>7}{'m2':>7}{'m3':>7}")
best=[]
for mode in ['mom','rev']:
    for TGT,S,H in [(60,60,30),(100,100,60),(150,150,90),(200,200,120),(80,120,60),(120,80,60),(300,150,180)]:
        for PULSE in [1.0,1.5,2.0]:
            r=run(mode,TGT,S,H,PULSE)
            if not r: continue
            n,wr,net,ev,dd,res=r
            print(f"{mode:>5}{TGT:>5}{S:>5}{H:>4}{PULSE:>5}{n:>6}{wr:>6.1f}{ev:>7.1f}{net:>8.0f}{abs(dd)*0.01:>6.0f}{res[0].sum():>7.0f}{res[1].sum():>7.0f}{res[2].sum():>7.0f}",flush=True)
            best.append((net,mode,TGT,S,H,PULSE,res))
best.sort(key=lambda x:-x[0])
print("\nأفضل 3 (كلها موجبة في 3 أشهر؟):")
for b in best[:3]:
    net,mode,TGT,S,H,PULSE,res=b
    allpos=all(r.sum()>0 for r in res)
    print(f"  {mode} T{TGT}/S{S}/H{H}/P{PULSE}: net={net:.0f} m1={res[0].sum():.0f} m2={res[1].sum():.0f} m3={res[2].sum():.0f} {'✅كل الأشهر موجبة' if allpos else '⚠️'}")
