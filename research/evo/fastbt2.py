import numpy as np, pandas as pd
from harness import load

def bt_fast(d, aT, bS, mode, pulse_th, chlen, trendlen, hold, hours_mask, atr_gate=0):
    bcl,acl,bhi,blo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['vol'],d['volavg'],d['nb']
    atr=d['rngavg']; hr=((d['t']%86400)//3600)
    hh=pd.Series(bhi).rolling(chlen).max().shift(1).values
    ll=pd.Series(blo).rolling(chlen).min().shift(1).values
    tr=bcl-np.roll(bcl,trendlen); tr[:trendlen]=0
    pulse=vol>pulse_th*volavg
    hm=np.isin(hr,hours_mask) if hours_mask else np.ones(nb,bool)
    gate=(atr>=atr_gate*(acl-bcl)) if atr_gate>0 else np.ones(nb,bool)
    valid=(np.arange(nb)>=max(chlen,trendlen)+1)&(np.arange(nb)<nb-hold-1)&gate&pulse&hm
    brk_up=bcl>hh+20; brk_dn=bcl<ll-20
    if mode=='pullback':
        ls=valid&brk_dn&(tr>0); ss=valid&brk_up&(tr<0)
    elif mode=='fade':
        ls=valid&brk_dn; ss=valid&brk_up
    else:
        ls=valid&brk_dn&(tr>0); ss=valid&brk_up&(tr<0)
    fmin=np.full(nb,np.nan); fmax=np.full(nb,np.nan)
    fmin[:-hold]=np.lib.stride_tricks.sliding_window_view(blo[1:],hold).min(axis=1)
    fmax[:-hold]=np.lib.stride_tricks.sliding_window_view(bhi[1:],hold).max(axis=1)
    pnls=[]; last=-1
    for i in np.where(ls|ss)[0]:
        if i<=last: continue
        A=atr[i-1]
        if not(A>0): continue
        tgt=aT*A; stp=bS*A; dr=1 if ls[i] else -1
        ent=acl[i-1] if dr>0 else bcl[i-1]
        if dr>0:
            pnl = -stp if fmin[i]<=ent-stp else (tgt if fmax[i]>=ent+tgt else bcl[min(i+hold,nb-1)]-ent)
        else:
            pnl = -stp if fmax[i]>=ent+stp else (tgt if fmin[i]<=ent-tgt else ent-acl[min(i+hold,nb-1)])
        pnls.append(pnl); last=i+hold
    return np.array(pnls)

def fitness(d1,d2,cfg):
    a1=bt_fast(d1,*cfg); a2=bt_fast(d2,*cfg)
    a=np.concatenate([a1,a2]) if len(a1)+len(a2) else np.array([0])
    if len(a)<20: return -1e9,None
    net=a.sum()*0.01; e=np.cumsum(a); dd=abs((e-np.maximum.accumulate(e)).min())*0.01
    fit=net - 0.5*dd   # net with DD penalty
    return fit,dict(net=net,dd=dd,wr=(a>0).mean()*100,n=len(a))
