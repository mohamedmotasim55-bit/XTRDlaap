import numpy as np, pandas as pd, json
exec(open('v5.py').read().split('grid=[]')[0])
grid=[]
for BE in [60,80,100,120]:
    for TR in [60,80,100]:
        for S in [80,100,120]:
            for EXITL in [10,15]:
                grid.append(dict(L1=30,L2=0,EXITL=EXITL,S=S,PULSE=1.2,BE=BE,TRAIL=TR))
print(f"تركيبات {len(grid)}",flush=True)
res=[]
for g in grid:
    nets=[]
    for m in ['m1','m2','m3']:
        s=st5(eng5(m,**g))
        if not s: nets=None;break
        nets.append((s['net'],s['rf'],s['n']))
    if nets is None: continue
    res.append((g,nets))
res.sort(key=lambda x:-min(n[0] for n in x[1]))
print(f"{'BE':>5}{'TR':>5}{'S':>5}{'EXIT':>5}{'m1':>8}{'m2':>8}{'m3':>8}{'أسوأ':>8}{'RFmin':>6}{'صفقات':>7}")
for g,n in res[:12]:
    print(f"{g['BE']:>5}{g['TRAIL']:>5}{g['S']:>5}{g['EXITL']:>5}{n[0][0]:>8.0f}{n[1][0]:>8.0f}{n[2][0]:>8.0f}{min(x[0] for x in n):>8.0f}{min(x[1] for x in n):>6.1f}{sum(x[2] for x in n):>7}",flush=True)
json.dump([(g,[list(x) for x in n]) for g,n in res[:10]],open('v6_top.json','w'))
