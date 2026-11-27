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
    bpm=60; nb=min(len(Bs),len(cnt))//bpm; B1=Bs[:nb*bpm]; ix=np.arange(0,nb*bpm,bpm)
    t=u[ix]
    d=dict(u=u,B=Bs,A=As,hi=np.maximum.reduceat(B1,ix),lo=np.minimum.reduceat(B1,ix),
           cl=B1[bpm-1::bpm],cps=np.add.reduceat(cnt[:nb*bpm],ix),nb=nb,
           day=(t//86400).astype(np.int32),hour=((t%86400)//3600).astype(np.int32))
    CACHE[m]=d; return d
def eng(m,L1=30,L2=15,L3=0,EXITL=10,S=80,PULSE=1.2,BE1=40,BE2=100,TR=60,DL=0,SESS=0):
    d=prep(m); hi,lo,cl,cps,nb,day,hr=d['hi'],d['lo'],d['cl'],d['cps'],d['nb'],d['day'],d['hour']
    avg=pd.Series(cps).rolling(60).mean().values
    pos=0;ent=0.0;stop=0.0;best=0.0;rec=[]; curday=-1; daypnl=0.0; blocked=False
    Ls=[x for x in (L1,L2,L3) if x>0]
    for i in range(max(Ls),nb):
        if day[i]!=curday: curday=day[i]; daypnl=0.0; blocked=False
        if pos==0:
            if blocked: continue
            if SESS and hr[i] in (23,0,1): continue
            up=False; dn=False
            for L in Ls:
                if cl[i]>hi[max(0,i-L):i].max(): up=True
                if cl[i]<lo[max(0,i-L):i].min(): dn=True
            brk=1 if up else (-1 if dn else 0)
            if brk==0 or not (cps[i]>PULSE*np.nan_to_num(avg[i])): continue
            pos=brk; ent=cl[i]+13*brk; stop=ent-S*brk; best=ent
        else:
            pnl=None
            if pos>0:
                best=max(best,cl[i]); prof=best-ent
                if BE1>0 and prof>=BE1: stop=max(stop,ent)
                if BE2>0 and prof>=BE2: stop=max(stop,ent+(BE2-BE1)*0.5)
                if TR>0 and prof>=BE1: stop=max(stop,best-TR)
                if cl[i]<=stop: pnl=stop-ent
                elif cl[i]<lo[max(0,i-EXITL):i].min(): pnl=cl[i]-13-ent
            else:
                best=min(best,cl[i]); prof=ent-best
                if BE1>0 and prof>=BE1: stop=min(stop,ent)
                if BE2>0 and prof>=BE2: stop=min(stop,ent-(BE2-BE1)*0.5)
                if TR>0 and prof>=BE1: stop=min(stop,best+TR)
                if cl[i]>=stop: pnl=ent-stop
                elif cl[i]>hi[max(0,i-EXITL):i].max(): pnl=ent-(cl[i]+13)
            if pnl is not None:
                rec.append(pnl); pos=0; daypnl+=pnl
                if DL>0 and daypnl<=-DL: blocked=True
    return np.array(rec) if rec else np.array([])
def st(a):
    if len(a)<10: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 99)
