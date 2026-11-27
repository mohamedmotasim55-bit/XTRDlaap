"""SELF-ADAPTING LOOP: run -> diagnose losers -> apply fix -> rerun. 100 cycles."""
import numpy as np, json
from harness import load

D={m:load(m) for m in ['m1','m2','m3']}

def backtest(d, cfg):
    """Trend-pullback entry with target/stop/hold/lock. Returns trade list with MFE/MAE."""
    bcl,acl,bhi,blo,ahi,alo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['vol'],d['volavg'],d['nb']
    hr=((d['t']%86400)//3600)
    trades=[]; i=1500
    while i<nb-1:
        if int(hr[i])!=1: i+=1; continue
        pulse=vol[i-1]>cfg['PULSE']*volavg[i-1]
        if not pulse: i+=1; continue
        hh=bhi[i-31:i-1].max(); ll=blo[i-31:i-1].min(); tr=bcl[i-1]-bcl[i-1-1440]
        dr=0
        if bcl[i-1]>hh+cfg['EXT'] and tr<0: dr=-1
        elif bcl[i-1]<ll-cfg['EXT'] and tr>0: dr=1
        if dr==0: i+=1; continue
        ent=acl[i-1] if dr>0 else bcl[i-1]
        k=min(i+cfg['HOLD'],nb-1); pnl=None; mfe=0.0; mae=0.0; reason='time'
        for j in range(i,k+1):
            fav=(bcl[j]-ent) if dr>0 else (ent-acl[j])
            if fav>mfe: mfe=fav
            if -fav>mae: mae=-fav
            if dr>0:
                if blo[j]<=ent-cfg['STOP']: pnl=-cfg['STOP']; reason='stop'; break
                if cfg['TGT'] and bhi[j]>=ent+cfg['TGT']: pnl=cfg['TGT']; reason='target'; break
            else:
                if ahi[j]>=ent+cfg['STOP']: pnl=-cfg['STOP']; reason='stop'; break
                if cfg['TGT'] and alo[j]<=ent-cfg['TGT']: pnl=cfg['TGT']; reason='target'; break
            if cfg['BE'] and mfe>=cfg['BE'] and (mfe-fav)>=cfg['TR']: pnl=fav; reason='lock'; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        trades.append(dict(i=i,pnl=pnl,mfe=mfe,mae=mae,reason=reason)); i=k+1
    return trades

def diagnose(trades):
    """Analyze LOSERS and return a fix."""
    L=[t for t in trades if t['pnl']<=0]
    if not L: return None, {}
    n=len(L)
    mfe_hi=sum(1 for t in L if t['mfe']>=60)/n      # went 60+ in favor then lost
    mfe_mid=sum(1 for t in L if t['mfe']>=30)/n
    stop_reason=sum(1 for t in L if t['reason']=='stop')/n
    quick=sum(1 for t in L if t['mae']>=60 and t['mfe']<20)/n  # immediate adverse
    stats=dict(losers=n,mfe60=mfe_hi,mfe30=mfe_mid,stopped=stop_reason,immediate=quick)
    if mfe_hi>0.35: fix='TARGET_TOO_FAR'      # many reached 60 but gave back
    elif mfe_mid>0.6: fix='ADD_LOCK'          # many reached 30
    elif quick>0.5: fix='TIGHTEN_ENTRY'       # immediate adverse = bad entry
    else: fix='TUNE_STOP'
    return fix, stats

def apply_fix(cfg, fix):
    c=dict(cfg)
    if fix=='TARGET_TOO_FAR':
        c['TGT']=max(60, c['TGT']-10) if c['TGT'] else 60
        if c['TGT']<86 and not c['BE']: c['BE']=20; c['TR']=10
    elif fix=='ADD_LOCK':
        c['BE']=max(15, c.get('BE',0) or 20); c['TR']=max(8, c.get('TR',0) or 10)
    elif fix=='TIGHTEN_ENTRY':
        c['PULSE']=min(2.5, c['PULSE']+0.2); c['EXT']=min(40, c['EXT']+5)
    else:
        c['STOP']=min(160, c['STOP']+10)
    return c

cfg=dict(EXT=20,PULSE=1.0,STOP=80,HOLD=45,TGT=86,BE=0,TR=0)
print("cycle,fix,losers,WR%,m1$,m2$,m3$,total$,cfg")
best=(None,-1e18)
for cyc in range(1,101):
    tr=[]
    for m in ['m1','m2']: tr+=backtest(D[m],cfg)
    fix,st=diagnose(tr)
    # measure current config on all 3
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        t=backtest(D[m],cfg); a=np.array([x['pnl'] for x in t]); nets.append(a.sum()*0.01 if len(a) else 0); allp+=list(a)
    allp=np.array(allp); tot=sum(nets)
    print(f"{cyc},{fix},{st.get('losers',0)},{ (allp>0).mean()*100 if len(allp) else 0:.1f},{nets[0]:.2f},{nets[1]:.2f},{nets[2]:.2f},{tot:.2f},{json.dumps(cfg)}",flush=True)
    if tot>best[1]: best=(dict(cfg),tot)
    cfg=apply_fix(cfg,fix)
print(f"\n=== BEST: {best[1]:.2f}$ with {best[0]} ===")
json.dump(dict(best=best),open('autoloop.json','w'),indent=1)
