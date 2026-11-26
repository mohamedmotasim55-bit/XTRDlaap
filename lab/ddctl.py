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
    bpm=60; nb=min(len(Bs),len(cnt))//bpm; N=nb*bpm; ix=np.arange(0,N,bpm)
    t=u[ix]
    d=dict(bhi=np.maximum.reduceat(Bs[:N],ix),blo=np.minimum.reduceat(Bs[:N],ix),bcl=Bs[bpm-1:N:bpm],
        ahi=np.maximum.reduceat(As[:N],ix),alo=np.minimum.reduceat(As[:N],ix),acl=As[bpm-1:N:bpm],
        nb=nb,day=(t//86400).astype(np.int32),hour=((t%86400)//3600).astype(np.int32))
    CACHE[m]=d; return d
def run(m,L1=40,EXITL=4,S=75,COOL=10,DL=0,HOURS=None,EQ=0):
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,nb,day,hr=d['bhi'],d['blo'],d['bcl'],d['ahi'],d['alo'],d['acl'],d['nb'],d['day'],d['hour']
    pos=0;ent=0.0;stop=0.0;rec=[];last_exit=-10**9;et=0
    cur=-1;dn_=0;blocked=False;eq=0.0;peak=0.0;killed=False
    for i in range(L1+1,nb):
        if killed: break
        if day[i]!=cur: cur=day[i]; dn_=0; blocked=False
        if pos==0:
            if blocked or i-last_exit<COOL: continue
            if HOURS and hr[i] not in HOURS: continue
            hh=bhi[i-1-L1:i-1].max(); ll=blo[i-1-L1:i-1].min()
            if bcl[i-1]>hh:   pos=-1; ent=bcl[i-1]; stop=ent+S
            elif bcl[i-1]<ll: pos=1; ent=acl[i-1]; stop=ent-S
            else: continue
            et=i
        if pos!=0:
            pnl=None
            if pos>0:
                if blo[i]<=stop: pnl=stop-ent
                elif i>et and bcl[i]<blo[max(0,i-EXITL):i].min(): pnl=bcl[i]-ent
            else:
                if ahi[i]>=stop: pnl=ent-stop
                elif i>et and acl[i]>ahi[max(0,i-EXITL):i].max(): pnl=ent-acl[i]
            if pnl is not None:
                rec.append(pnl); pos=0; last_exit=i
                eq+=pnl; peak=max(peak,eq)
                if EQ>0 and peak-eq>=EQ: killed=True
                if pnl<0: dn_+=1
                if DL>0 and dn_>=DL: blocked=True
    return np.array(rec) if rec else np.array([])
def st(a):
    if len(a)<10: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    mx=0;c=0
    for x in a:
        c=c+1 if x<=0 else 0; mx=max(mx,c)
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 99,streak=mx)
