import numpy as np, pandas as pd
P=0.01
def prep(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    bid=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/P
    ask=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/P
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=bid[last]; As=ask[last]
    bpm=60; nb=min(len(Bs),len(cnt))//bpm; N=nb*bpm; ix=np.arange(0,N,bpm)
    return dict(bhi=np.maximum.reduceat(Bs[:N],ix),blo=np.minimum.reduceat(Bs[:N],ix),bcl=Bs[bpm-1:N:bpm],
        ahi=np.maximum.reduceat(As[:N],ix),alo=np.minimum.reduceat(As[:N],ix),acl=As[bpm-1:N:bpm],nb=nb)
def mrev2(m,L1=60,LIM=0,W=3,EXITL=20,S=150,COOL=10,TMAX=240):
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,nb=d['bhi'],d['blo'],d['bcl'],d['ahi'],d['alo'],d['acl'],d['nb']
    pos=0;ent=0.0;stop=0.0;rec=[];last_exit=-10**9;et=0;pend=0;plim=0.0;ptime=0
    for i in range(L1+1,nb):
        if pos==0 and pend==0:
            if i-last_exit<COOL: continue
            hh=bhi[i-1-L1:i-1].max(); ll=blo[i-1-L1:i-1].min()
            if bcl[i-1]>hh: pend=-1; plim=bcl[i-1]+LIM; ptime=i
            elif bcl[i-1]<ll: pend=1; plim=acl[i-1]-LIM; ptime=i
        if pend!=0:
            if pend<0:
                if ahi[i]>=plim: pos=-1; ent=plim; stop=ent+S; et=i; pend=0
                elif i-ptime>=W: pend=0
            else:
                if blo[i]<=plim: pos=1; ent=plim; stop=ent-S; et=i; pend=0
                elif i-ptime>=W: pend=0
        if pos!=0:
            pnl=None
            if pos>0:
                if blo[i]<=stop: pnl=stop-ent
                elif i>et and bcl[i]<blo[max(0,i-EXITL):i].min(): pnl=bcl[i]-ent
                elif i-et>=TMAX: pnl=bcl[i]-ent
            else:
                if ahi[i]>=stop: pnl=ent-stop
                elif i>et and acl[i]>ahi[max(0,i-EXITL):i].max(): pnl=ent-acl[i]
                elif i-et>=TMAX: pnl=ent-acl[i]
            if pnl is not None: rec.append(pnl); pos=0; last_exit=i
    return np.array(rec) if rec else np.array([])
def st(a):
    if len(a)<10: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 99)
