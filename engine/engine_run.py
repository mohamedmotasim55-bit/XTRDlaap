"""ENGINE RUNNER: market feed -> snapshots -> engine.decide() -> execution sim."""
import numpy as np
from engine_core import Snapshot, Engine, TrendPullback, Fade

def load(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    A=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=B[last]; As=A[last]; nb=len(Bs)//60; N=nb*60; ix=np.arange(0,N,60)
    bcl=Bs[59:N:60]; acl=As[59:N:60]
    bhi=np.maximum.reduceat(Bs[:N],ix); blo=np.minimum.reduceat(Bs[:N],ix)
    ahi=np.maximum.reduceat(As[:N],ix); alo=np.minimum.reduceat(As[:N],ix)
    vol=np.add.reduceat(cnt[:N],ix)
    return dict(bcl=bcl,acl=acl,bhi=bhi,blo=blo,ahi=ahi,alo=alo,vol=vol,nb=nb,t=u[ix])

def snapshots(d):
    """Build a Snapshot for every minute (what the engine sees at that moment)."""
    bcl=d['bcl']; acl=d['acl']; bhi=d['bhi']; blo=d['blo']; vol=d['vol']; nb=d['nb']
    volavg=np.convolve(vol,np.ones(60)/60,'full')[:nb]
    rng=bhi-blo; rngavg=np.convolve(rng,np.ones(60)/60,'full')[:nb]
    hr=((d['t']%86400)//3600)
    snaps={}
    for i in range(1500,nb-1):
        snaps[i]=Snapshot(idx=i,hour=int(hr[i]),bid=bcl[i-1],ask=acl[i-1],
            spread=acl[i-1]-bcl[i-1], pulse=vol[i-1]/volavg[i-1] if volavg[i-1]>0 else 1.0,
            m1s=bcl[i-1]-bcl[i-2], m30s=bcl[i-1]-bcl[i-31], m60s=bcl[i-1]-bcl[i-61],
            m5m=bcl[i-1]-bcl[i-6], m24h=bcl[i-1]-bcl[i-1-1440],
            ch_hi=bhi[i-31:i-1].max(), ch_lo=blo[i-31:i-1].min(), atr=rngavg[i-1])
    return snaps

def run(d, engine, snaps):
    bcl=d['bcl']; acl=d['acl']; bhi=d['bhi']; blo=d['blo']; ahi=d['ahi']; alo=d['alo']; nb=d['nb']
    trades=[]; pos=0; ent=0.0; stop=0.0; hold=0; et=0
    for i in range(1500,nb-1):
        s=snaps.get(i)
        if s is None: continue
        if pos!=0:
            pnl=None
            for j in range(i, min(i+1,nb)):
                if pos>0:
                    if blo[j]<=stop: pnl=stop-ent; break
                    if i-et>=hold: pnl=bcl[i]-ent; break
                else:
                    if ahi[j]>=stop: pnl=ent-stop; break
                    if i-et>=hold: pnl=ent-acl[i]; break
            if pnl is not None:
                trades.append((et,pnl,engine.log[-1][3] if engine.log else '-')); pos=0
            continue
        d2=engine.decide(s)
        if d2.action in ('BUY','SELL'):
            pos=1 if d2.action=='BUY' else -1
            ent=acl[i] if pos>0 else bcl[i]
            stop=ent-d2.stop if pos>0 else ent+d2.stop
            hold=d2.hold_min; et=i
    return trades

print("=== المحرك المستقل — قراءة · قرار · تنفيذ ===")
for cfg,strats in [("TREND_PULLBACK فقط",[TrendPullback()]),("FADE فقط",[Fade()]),("الدمج",[TrendPullback(),Fade()])]:
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        d=load(m); eng=Engine(strats); tr=run(d,eng,snapshots(d))
        a=np.array([t[1] for t in tr]); nets.append(a.sum()*0.01); allp.append(a)
    allp=np.concatenate(allp)
    e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
    print(f"\n{cfg}: n={len(allp)} WR={(allp>0).mean()*100:.1f}% net=${allp.sum()*0.01:.2f} DD=${abs(dd)*0.01:.2f}")
    print(f"  شهريًا: m1=${nets[0]:.2f} m2=${nets[1]:.2f} m3=${nets[2]:.2f}")
print("\n=== سجل قرارات المحرك (عينة من m3) ===")
d=load('m3'); eng=Engine([TrendPullback()]); tr=run(d,eng,snapshots(d))
for i,h,act,strat,reason in eng.log[:10]:
    print(f"  [{i}] h={h} {act:>4} | {strat} | {reason}")
