import numpy as np
from harness import load,signals,execute,Eng
D={m:load(m) for m in ['m1','m2','m3']}
print("=== الثبات الشهري (كل شهر على حدة) ===")
print(f"{'engine':<16}{'m1$':>7}{'m2$':>7}{'m3$':>7}{'كلها+?':>8}{'صفقات':>7}{'WR%':>6}")
for name,stop,hold in [('TREND_PULLBACK',80,45),('FADE',80,30),('MOMENTUM',60,20)]:
    e=Eng(name,stop,hold,0,(1,))
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        r=execute(D[m],e,signals(D[m],e)); nets.append(r['net']*0.01); allp.append(r['pnl'])
    allp=np.concatenate(allp)
    ok='✅' if all(n>0 for n in nets) else '⚠️'
    print(f"{name:<16}{nets[0]:>7.2f}{nets[1]:>7.2f}{nets[2]:>7.2f}{ok:>8}{len(allp):>7}{(allp>0).mean()*100:>6.1f}")
print("\n=== دمج TREND_PULLBACK + FADE ===")
e1=Eng('TREND_PULLBACK',80,45,0,(1,)); e2=Eng('FADE',80,30,0,(1,))
for m in ['m1','m2','m3']:
    r1=execute(D[m],e1,signals(D[m],e1)); r2=execute(D[m],e2,signals(D[m],e2))
    comb=np.concatenate([r1['pnl'],r2['pnl']])
    e=np.cumsum(comb); dd=(e-np.maximum.accumulate(e)).min()
    print(f"  {m}: n={len(comb)} net=${comb.sum()*0.01:.2f} WR={(comb>0).mean()*100:.1f}% DD=${abs(dd)*0.01:.2f}")
print("\n=== حساسية المعلمات (robustness) — TREND_PULLBACK ===")
for stop in [60,70,80,90,100]:
    for hold in [30,45,60]:
        e=Eng('TREND_PULLBACK',stop,hold,0,(1,))
        allp=np.concatenate([execute(D[m],e,signals(D[m],e))['pnl'] for m in ['m1','m2','m3']])
        print(f"  stop={stop} hold={hold}: n={len(allp)} net=${allp.sum()*0.01:.0f} EV={allp.mean():.1f}")
