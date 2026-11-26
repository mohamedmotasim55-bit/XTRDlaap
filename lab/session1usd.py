import numpy as np
from vsec import run
print("=== هدف 1$ صافي (126 نقطة) — كل جلسة — ارتداد ومتابعة ===")
print(f"{'hr':>3}{'mode':>7}{'S':>4}{'m1':>7}{'m2':>7}{'m3':>7}{'net':>7}{'WR':>6}{'n':>4}{'$DD':>6}")
res=[]
for hr in range(24):
    for mode in ['fade','follow']:
        for S in [150,250]:
            tot=[];nets=[];ok=True
            for m in ['m1','m2','m3']:
                # vsec.run: DT trend filter off (DT=0); we emulate follow by DT sign trick not needed
                # use TGT=126, stop=S, HOLD=120, hour=hr
                a=run(m,EXT=20,S=S,HOLD=120,TGT=126,BE1=0,TR=0,HOURS=(hr,),COOL=15,DT=0)
                if len(a)<10: ok=False;break
                tot.append(a); nets.append(a.sum())
            if not ok: continue
            allp=np.concatenate(tot); e=np.cumsum(allp); dd=(e-np.maximum.accumulate(e)).min()
            wr=(allp>0).mean()*100
            res.append((hr,mode,S,nets,allp.sum(),wr,len(allp),dd))
# show best by net
res.sort(key=lambda r:-r[4])
for r in res[:14]:
    hr,mode,S,nets,net,wr,n,dd=r
    print(f"{hr:>3}{mode:>7}{S:>4}{nets[0]:>7.0f}{nets[1]:>7.0f}{nets[2]:>7.0f}{net:>7.0f}{wr:>6.1f}{n:>4}{abs(dd)*0.01:>6.2f}",flush=True)
