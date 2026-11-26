import numpy as np, pandas as pd
P=0.01; CACHE={}
def prep(m):
    if m in CACHE: return CACHE[m]
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    bid=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/P
    ask=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/P
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=bid[last]; As=ask[last]
    bpm=60; nb=min(len(Bs),len(cnt))//bpm; N=nb*bpm
    ix=np.arange(0,N,bpm)
    d=dict(bhi=np.maximum.reduceat(Bs[:N],ix),blo=np.minimum.reduceat(Bs[:N],ix),bcl=Bs[bpm-1:N:bpm],
           ahi=np.maximum.reduceat(As[:N],ix),alo=np.minimum.reduceat(As[:N],ix),acl=As[bpm-1:N:bpm],
           cps=np.add.reduceat(cnt[:N],ix),nb=nb,t=u[ix])
    CACHE[m]=d; return d
def mrev(m,L1=40,EXT=0,TGT=0,S=100,COOL=10,TMAX=240):
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,nb=d['bhi'],d['blo'],d['bcl'],d['ahi'],d['alo'],d['acl'],d['nb']
    pos=0;ent=0.0;stop=0.0;target=0.0;rec=[];last_exit=-10**9;et=0
    for i in range(L1+1,nb):
        if pos==0:
            if i-last_exit<COOL: continue
            hh=bhi[i-1-L1:i-1].max(); ll=blo[i-1-L1:i-1].min()
            up=bcl[i-1]>hh+EXT; dn=bcl[i-1]<ll-EXT
            if not (up or dn): continue
            mid=(hh+ll)/2
            if up:
                pos=-1; ent=bcl[i-1]; stop=ent+S
                target=ent-TGT if TGT>0 else mid
                if target>=ent: target=ent-50
            else:
                pos=1; ent=acl[i-1]; stop=ent-S
                target=ent+TGT if TGT>0 else mid
                if target<=ent: target=ent+50
            et=i
        if pos!=0:
            pnl=None
            if pos>0:
                if blo[i]<=stop: pnl=stop-ent
                elif bhi[i]>=target: pnl=target-ent
                elif i-et>=TMAX: pnl=bcl[i]-ent
            else:
                if ahi[i]>=stop: pnl=ent-stop
                elif alo[i]<=target: pnl=ent-target
                elif i-et>=TMAX: pnl=ent-acl[i]
            if pnl is not None: rec.append(pnl); pos=0; last_exit=i
    return np.array(rec) if rec else np.array([])
def st(a):
    if len(a)<10: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 99)
