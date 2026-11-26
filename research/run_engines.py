import numpy as np
from harness import load,signals,execute,Eng
D={m:load(m) for m in ['m1','m2','m3']}
print("=== FOUR-COUNT FRAMEWORK — 5 engines × 3 months ===")
print(f"{'engine':<16}{'raw_events':>11}{'candidates':>11}{'executable':>11}{'net_profit':>11}{'WR%':>6}{'EV':>7}{'$/mo':>7}")
for name,stop,hold,tgt in [('TREND_PULLBACK',80,45,0),('MOMENTUM',60,20,0),('FADE',80,30,0),('VOL_BURST',50,10,0),('RANGE_EXP',60,30,0)]:
    e=Eng(name,stop,hold,tgt,(1,))
    tot=dict(raw=0,cand=0,ex=0,win=0,net=0); allp=[]
    for m in ['m1','m2','m3']:
        r=execute(D[m],e,signals(D[m],e))
        tot['raw']+=D[m]['raw_events']; tot['cand']+=r['cand']; tot['ex']+=r['execu']
        tot['win']+=r['win']; tot['net']+=r['net']; allp.append(r['pnl'])
    allp=np.concatenate(allp)
    print(f"{name:<16}{tot['raw']:>11,}{tot['cand']:>11,}{tot['ex']:>11,}{tot['win']:>11,}{(allp>0).mean()*100:>6.1f}{allp.mean():>7.1f}{tot['net']*0.01/3:>7.0f}",flush=True)
