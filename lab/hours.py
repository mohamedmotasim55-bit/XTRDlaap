import numpy as np
from ddctl import run,st
print(f"{'hr':>3}{'m1':>7}{'m2':>7}{'m3':>7}{'net':>8}{'DD':>7}{'RF':>6}{'n':>5}{'WR':>6}")
for hr in range(24):
    tot=[];nets=[];ok=True
    for m in ['m1','m2','m3']:
        a=run(m,L1=40,EXITL=4,S=35,COOL=10,DL=0,HOURS=(hr,),EXT=50); s=st(a)
        if not s: ok=False;break
        nets.append(s['net']); tot.append(a)
    if not ok:
        print(f"{hr:>3}  — عدد صفقات غير كافٍ"); continue
    allp=np.concatenate(tot); e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
    print(f"{hr:>3}{nets[0]:>7.0f}{nets[1]:>7.0f}{nets[2]:>7.0f}{allp.sum():>8.0f}{dd:>7.0f}{allp.sum()/abs(dd) if dd<0 else 0:>6.2f}{len(allp):>5}{(allp>0).mean()*100:>6.1f}",flush=True)
