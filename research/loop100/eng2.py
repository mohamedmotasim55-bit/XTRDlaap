"""XTRD ENGINE v2 — momentum + pulse + tick-flow + PROTECTIVE PROFIT LOCK."""
import numpy as np

def load_sec(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    A=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    return u, B[last], A[last], cnt

def run(m, MOM=20, W=10, PULSE=1.5, STOP=80, TGT=0, HOLD=60,
        BE=30, TR=15, COOL=5):
    """Momentum burst entry + protective profit lock.
    BE = profit level (pts) that arms the lock; TR = retrace from peak that triggers close."""
    u,B,A,cnt=load_sec(m); n=len(B)
    cps=np.zeros(n); np.add.at(cps,np.searchsorted(u,np.unique(u)[np.searchsorted(u,np.unique(u))]*0+cnt*0),0)  # noop
    cpsavg=np.convolve(cnt,np.ones(300)/300,'full')[:n]
    pnls=[]; i=W+300; last_exit=-10**9
    while i<n-HOLD-1:
        if i<=last_exit: i+=1; continue
        mv=B[i]-B[i-W]
        if abs(mv)<MOM: i+=1; continue
        if cnt[i] < PULSE*cpsavg[i]: i+=1; continue
        dr=1 if mv>0 else -1
        ent=A[i] if dr>0 else B[i]
        mfe=0.0; locked=False; pnl=None
        for j in range(i+1, min(i+HOLD, n-1)):
            fav=(B[j]-ent) if dr>0 else (ent-A[j])
            if fav>mfe: mfe=fav
            if dr>0:
                if B[j]<=ent-STOP: pnl=-STOP; break
                if TGT and B[j]>=ent+TGT: pnl=TGT; break
            else:
                if A[j]>=ent+STOP: pnl=-STOP; break
                if TGT and A[j]<=ent-TGT: pnl=TGT; break
            # PROTECTIVE LOCK: in profit >= BE and retraced TR from peak -> close with profit
            if mfe>=BE and (mfe-fav)>=TR:
                pnl=fav; locked=True; break
        if pnl is None:
            k=min(i+HOLD,n-1); pnl=(B[k]-ent) if dr>0 else (ent-A[k])
        pnls.append(pnl); last_exit=j if pnl is not None else i+HOLD
        i=last_exit+1+COOL
    a=np.array(pnls)
    if len(a)==0: return dict(n=0,wr=0,net=0,dd=0,ev=0)
    e=np.cumsum(a); dd=(e-np.maximum.accumulate(e)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,ev=a.mean())
