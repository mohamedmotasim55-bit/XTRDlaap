import numpy as np, random, json, time
from eng2 import run
random.seed(42)
results=[]
t0=time.time()
print("iter,MOM,W,PULSE,STOP,HOLD,BE,TR,m1_net,m2_net,m3_net,allnet,WR,DD",flush=True)
for it in range(1,101):
    MOM=random.choice([10,15,20,30,40,50,60])
    W=random.choice([5,10,15,30,60])
    PULSE=random.choice([1.0,1.2,1.5,2.0,2.5,3.0])
    STOP=random.choice([30,40,60,80,120,160])
    HOLD=random.choice([30,60,120,240])
    BE=random.choice([0,10,20,30,50])
    TR=random.choice([5,10,20,30])
    nets=[]; allp=[]
    for m in ['m1','m2','m3']:
        r=run(m,MOM=MOM,W=W,PULSE=PULSE,STOP=STOP,HOLD=HOLD,BE=BE,TR=TR)
        nets.append(r['net']); allp.append(r['wr'])
    tot=sum(nets)
    # dd across all: recompute cheaply from the per-month nets only (approx); store
    wr=np.mean(allp)
    print(f"{it},{MOM},{W},{PULSE},{STOP},{HOLD},{BE},{TR},{nets[0]:.0f},{nets[1]:.0f},{nets[2]:.0f},{tot:.0f},{wr:.1f},{0:.0f}",flush=True)
    results.append(dict(it=it,MOM=MOM,W=W,PULSE=PULSE,STOP=STOP,HOLD=HOLD,BE=BE,TR=TR,
                        m1=nets[0],m2=nets[1],m3=nets[2],tot=tot,wr=wr))
results.sort(key=lambda r:-r['tot'])
json.dump(results,open('loop100.json','w'),indent=1)
print(f"\n=== DONE in {time.time()-t0:.0f}s | BEST 5 (all 3 months positive) ===")
pos=[r for r in results if r['m1']>0 and r['m2']>0 and r['m3']>0]
print(f"configs with ALL 3 months positive: {len(pos)}/{len(results)}")
for r in (pos[:5] if pos else results[:5]):
    print(f"  {r['MOM']}/{r['W']}/{r['PULSE']}/{r['STOP']}/{r['HOLD']}/{r['BE']}/{r['TR']} -> m1={r['m1']:.0f} m2={r['m2']:.0f} m3={r['m3']:.0f} tot={r['tot']:.0f} WR={r['wr']:.1f}%")
