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
    bhi=np.maximum.reduceat(Bs[:N],ix); blo=np.minimum.reduceat(Bs[:N],ix); bcl=Bs[bpm-1:N:bpm]
    ahi=np.maximum.reduceat(As[:N],ix); alo=np.minimum.reduceat(As[:N],ix); acl=As[bpm-1:N:bpm]
    cps=np.add.reduceat(cnt[:N],ix); t=u[ix]
    d=dict(bhi=bhi,blo=blo,bcl=bcl,ahi=ahi,alo=alo,acl=acl,cps=cps,nb=nb,
           day=(t//86400).astype(np.int32),hour=((t%86400)//3600).astype(np.int32))
    CACHE[m]=d; return d
def eng(m,L1=60,L2=0,EXITL=20,S=200,PULSE=1.0,BE1=0,TR=0,SESS=0,TF=0,TDIR=0,REV=0,COOL=0):
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,cps,nb,day,hr=(d['bhi'],d['blo'],d['bcl'],d['ahi'],
        d['alo'],d['acl'],d['cps'],d['nb'],d['day'],d['hour'])
    avg=pd.Series(cps).rolling(60).mean().values
    Ls=[x for x in (L1,L2) if x>0]; Lm=max(Ls)
    pos=0;ent=0.0;stop=0.0;best=0.0;rec=[];last_exit=-10**9
    for i in range(Lm,nb):
        if pos==0:
            if i-last_exit<COOL: continue
            if SESS and hr[i] in (23,0,1): continue
            up=False;dn=False
            for L in Ls:
                if bcl[i-1]>bhi[max(0,i-1-L):i-1].max(): up=True
                if bcl[i-1]<blo[max(0,i-1-L):i-1].min(): dn=True
            brk=1 if up else (-1 if dn else 0)
            if brk==0 or not (cps[i-1]>PULSE*np.nan_to_num(avg[i-1])): continue
            if REV: brk=-brk
            if TF>0 or TDIR:
                r240=bcl[i-1]-bcl[max(0,i-241)]
                if TF>0 and abs(r240)<TF: continue
                if TDIR and (r240*brk)<=0: continue
            if brk>0: ent=acl[i-1]
            else: ent=bcl[i-1]
            stop=ent-S*brk; best=ent; pos=brk; et=i
        if pos!=0:
            pnl=None
            if pos>0:
                if bhi[i]>best: best=bhi[i]
                prof=best-ent
                if BE1>0 and prof>=BE1: stop=max(stop,ent)
                if TR>0 and prof>=BE1: stop=max(stop,best-TR)
                if blo[i]<=stop: pnl=stop-ent
                elif i>et and bcl[i]<blo[max(0,i-EXITL):i].min(): pnl=bcl[i]-ent
            else:
                if alo[i]<best: best=alo[i]
                prof=ent-best
                if BE1>0 and prof>=BE1: stop=min(stop,ent)
                if TR>0 and prof>=BE1: stop=min(stop,best+TR)
                if ahi[i]>=stop: pnl=ent-stop
                elif i>et and acl[i]>ahi[max(0,i-EXITL):i].max(): pnl=ent-acl[i]
            if pnl is not None: rec.append(pnl); pos=0; last_exit=i
    return np.array(rec) if rec else np.array([])
def st(a):
    if len(a)<10: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 99)
