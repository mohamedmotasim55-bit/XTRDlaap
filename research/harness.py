import numpy as np
from dataclasses import dataclass
# ---------- DATA ----------
def load(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    A=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=B[last]; As=A[last]; nb=len(Bs)//60; N=nb*60; ix=np.arange(0,N,60)
    d=dict(bcl=Bs[59:N:60],acl=As[59:N:60],
           bhi=np.maximum.reduceat(Bs[:N],ix),blo=np.minimum.reduceat(Bs[:N],ix),
           ahi=np.maximum.reduceat(As[:N],ix),alo=np.minimum.reduceat(As[:N],ix),
           vol=np.add.reduceat(cnt[:N],ix),nb=nb,n=nb,t=u[ix],
           raw_events=len(u),raw_ticks=len(msc))
    d['volavg']=np.convolve(d['vol'],np.ones(60)/60,'full')[:nb]
    d['rng']=d['bhi']-d['blo']; d['rngavg']=np.convolve(d['rng'],np.ones(60)/60,'full')[:nb]
    return d

@dataclass
class Eng:
    name:str; stop:int; hold:int; tgt:int; hours:tuple

def signals(d,e):
    """returns list of (i, dir) candidate entries at bar i (open of i)"""
    bcl,acl,bhi,blo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['vol'],d['volavg'],d['nb']
    hr=((d['t']%86400)//3600); out=[]; i=1500
    while i<nb-1:
        if e.hours and int(hr[i]) not in e.hours: i+=1; continue
        pulse=vol[i-1]>1.0*volavg[i-1]
        if e.name=='TREND_PULLBACK':
            hh=bhi[i-31:i-1].max(); ll=blo[i-31:i-1].min(); tr=bcl[i-1]-bcl[i-1-1440]
            if not pulse: i+=1; continue
            if bcl[i-1]>hh+20 and tr<0: out.append((i,-1))
            elif bcl[i-1]<ll-20 and tr>0: out.append((i,1))
        elif e.name=='MOMENTUM':
            m5=bcl[i-1]-bcl[i-6]; tr=bcl[i-1]-bcl[i-1-60]
            if vol[i-1]>1.5*volavg[i-1] and m5>20 and tr>0: out.append((i,1))
            elif vol[i-1]>1.5*volavg[i-1] and m5<-20 and tr<0: out.append((i,-1))
        elif e.name=='FADE':
            hh=bhi[i-31:i-1].max(); ll=blo[i-31:i-1].min()
            if not pulse: i+=1; continue
            if bcl[i-1]>hh+20: out.append((i,-1))
            elif bcl[i-1]<ll-20: out.append((i,1))
        elif e.name=='VOL_BURST':
            if vol[i-1]>3.0*volavg[i-1]:
                if bcl[i-1]>bcl[i-2]: out.append((i,1))
                elif bcl[i-1]<bcl[i-2]: out.append((i,-1))
        elif e.name=='RANGE_EXP':
            if d['rng'][i-1]>2.0*d['rngavg'][i-1]:
                if bcl[i-1]>bcl[i-2]: out.append((i,1))
                elif bcl[i-1]<bcl[i-2]: out.append((i,-1))
        i+=1
    return out

def execute(d,e,sig,spread_max=60,min_stop=10):
    bcl,acl,bhi,blo,ahi,alo,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['nb']
    cand=len(sig); execu=0; wins=0; pnls=[]; costs=[]
    last_exit=-10**9
    for i,dr in sig:
        if i<=last_exit: continue
        sp=acl[i-1]-bcl[i-1]
        if sp>spread_max or e.stop<min_stop: continue
        execu+=1
        ent=acl[i-1] if dr>0 else bcl[i-1]
        k=min(i+e.hold,nb-1); pnl=None
        for j in range(i,k+1):
            if dr>0:
                if blo[j]<=ent-e.stop: pnl=-e.stop; break
                if e.tgt and bhi[j]>=ent+e.tgt: pnl=e.tgt; break
            else:
                if ahi[j]>=ent+e.stop: pnl=-e.stop; break
                if e.tgt and alo[j]<=ent-e.tgt: pnl=e.tgt; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        pnls.append(pnl); last_exit=k
        if pnl>0: wins+=1
    a=np.array(pnls)
    return dict(cand=cand,execu=execu,win=wins,pnl=a,net=a.sum() if len(a) else 0,
                wr=(a>0).mean()*100 if len(a) else 0,ev=a.mean() if len(a) else 0)
