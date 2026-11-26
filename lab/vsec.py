import numpy as np, sys
P=0.01
def load(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    bid=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/P
    ask=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/P
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    return u,bid[last],ask[last]
def run(m,L1=40,EXT=50,S=30,HOLD=45,COOL=5,BE1=12,TR=8,HOURS=(1,),DL=0,TFMAX=0,TGT=0):
    u,B,A=load(m); n=len(B); bpm=60; nb=n//bpm
    ix=np.arange(0,nb*bpm,bpm)
    bhi=np.maximum.reduceat(B[:nb*bpm],ix); blo=np.minimum.reduceat(B[:nb*bpm],ix); bcl=B[bpm-1:nb*bpm:bpm]
    ahi=np.maximum.reduceat(A[:nb*bpm],ix); alo=np.minimum.reduceat(A[:nb*bpm],ix); acl=A[bpm-1:nb*bpm:bpm]
    hr=((u[ix]%86400)//3600)
    pos=0;ent=0.0;stop=0.0;best=0.0;rec=[];last_exit=-10**9;et=0;cur=-1;dn_=0;blk=False
    for t in range(L1*bpm,nb*bpm):
        if pos==0:
            if t%60: continue
            mi=t//60
            if mi<L1+1 or mi-last_exit<COOL or hr[mi] not in HOURS or blk: continue
            hh=bhi[mi-1-L1:mi-1].max(); ll=blo[mi-1-L1:mi-1].min()
            if TFMAX>0:
                r240=bcl[mi-1]-bcl[max(0,mi-241)]
                if abs(r240)>TFMAX: continue
            if bcl[mi-1]>hh+EXT:   pos=-1; ent=B[t]; stop=ent+S; best=ent; et=mi; tg=ent-TGT
            elif bcl[mi-1]<ll-EXT: pos=1; ent=A[t]; stop=ent-S; best=ent; et=mi; tg=ent+TGT
            else: continue
        if pos!=0:
            pnl=None
            if pos>0:
                if B[t]>best: best=B[t]
                pr=best-ent
                if BE1>0 and pr>=BE1: stop=max(stop,ent)
                if pr>=BE1 and TR>0: stop=max(stop,best-TR)
                if B[t]<=stop: pnl=stop-ent
                elif TGT and B[t]>=tg: pnl=TGT
                elif (t//60)-et>=HOLD: pnl=B[t]-ent
            else:
                if A[t]<best: best=A[t]
                pr=ent-best
                if BE1>0 and pr>=BE1: stop=min(stop,ent)
                if pr>=BE1 and TR>0: stop=min(stop,best+TR)
                if A[t]>=stop: pnl=ent-stop
                elif TGT and A[t]<=tg: pnl=TGT
                elif (t//60)-et>=HOLD: pnl=ent-A[t]
            if pnl is not None:
                rec.append(pnl); pos=0; last_exit=t//60
                d0=int(u[t]//86400)
                if d0!=cur: cur=d0; dn_=0; blk=False
                if pnl<0: dn_+=1
                if DL>0 and dn_>=DL: blk=True
    return np.array(rec) if rec else np.array([])
if __name__=="__main__":
    for cfg in [dict(BE1=12,TR=8,S=30),dict(BE1=12,TR=15,S=35),dict(BE1=20,TR=15,S=35),dict(BE1=0,TR=0,S=35)]:
        tot=[];nets=[]
        for m in ['m1','m2','m3']:
            a=run(m,**cfg); tot.append(a); nets.append(a.sum() if len(a) else 0)
        allp=np.concatenate(tot); e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
        print(f"BE1={cfg['BE1']:2d} TR={cfg['TR']:2d} S={cfg['S']:2d} | m1 {nets[0]:+7.0f} m2 {nets[1]:+7.0f} m3 {nets[2]:+7.0f} | net {allp.sum():+8.0f} DD {dd:6.0f} RF {allp.sum()/abs(dd) if dd<0 else 0:5.1f} n={len(allp):3d} WR={(allp>0).mean()*100:4.1f}%",flush=True)
