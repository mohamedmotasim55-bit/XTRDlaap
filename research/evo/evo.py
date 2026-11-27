"""EVOLUTIONARY LOOP — accurate minute backtest, each generation builds on the best."""
import numpy as np, random, json, time
from harness import load
D={m:load(m) for m in ['m1','m2','m3']}
def bt(d,cfg):
    aT,bS,mode,pulse_th,chlen,trendlen,hold,hours,atr_gate=cfg
    bcl,acl,bhi,blo,ahi,alo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['vol'],d['volavg'],d['nb']
    atr=d['rngavg']; hr=((d['t']%86400)//3600); pnls=[]; last=-1
    hm=np.isin(hr,hours) if hours else np.ones(nb,bool)
    gate=(atr>=atr_gate*(acl-bcl)) if atr_gate>0 else np.ones(nb,bool)
    for i in range(max(chlen,trendlen)+1,nb-hold-1):
        if i<=last: continue
        if not hm[i] or not gate[i]: continue
        if vol[i-1]<=pulse_th*volavg[i-1]: continue
        A=atr[i-1]
        if not(A>0): continue
        hh=bhi[i-chlen-1:i-1].max(); ll=blo[i-chlen-1:i-1].min(); tr=bcl[i-1]-bcl[i-1-trendlen]
        dr=0
        if mode=='pullback':
            if bcl[i-1]>hh+20 and tr<0: dr=-1
            elif bcl[i-1]<ll-20 and tr>0: dr=1
        elif mode=='fade':
            if bcl[i-1]>hh+20: dr=-1
            elif bcl[i-1]<ll-20: dr=1
        if dr==0: continue
        tgt=aT*A; stp=bS*A
        ent=acl[i-1] if dr>0 else bcl[i-1]; k=min(i+hold,nb-1); pnl=None
        for j in range(i,k+1):
            if dr>0:
                if blo[j]<=ent-stp: pnl=-stp; break
                if tgt and bhi[j]>=ent+tgt: pnl=tgt; break
            else:
                if ahi[j]>=ent+stp: pnl=-stp; break
                if tgt and alo[j]<=ent-tgt: pnl=tgt; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        pnls.append(pnl); last=k
    return np.array(pnls)
def fit(cfg):
    a1=bt(D['m1'],cfg); a2=bt(D['m2'],cfg)
    a=np.concatenate([a1,a2])
    if len(a)<25: return -1e9,None
    net=a.sum()*0.01; e=np.cumsum(a); dd=abs((e-np.maximum.accumulate(e)).min())*0.01
    return net-0.6*dd, dict(net=net,dd=dd,wr=(a>0).mean()*100,n=len(a))
def rand_cfg():
    return (random.choice([1.5,2,3,4,6]), random.choice([1,1.5,2,3]),
            random.choice(['pullback','fade']), random.choice([0.8,1.0,1.3,1.6]),
            random.choice([15,30,60]), random.choice([240,720,1440]),
            random.choice([60,120,240]),
            tuple(sorted(random.sample(range(24),random.choice([3,4,5,6,24])))),
            random.choice([0,0,3,5]))
def mutate(c):
    c=list(c)
    if random.random()<0.5: c[0]=random.choice([1.5,2,3,4,6])
    if random.random()<0.5: c[1]=random.choice([1,1.5,2,3])
    if random.random()<0.2: c[2]=random.choice(['pullback','fade'])
    if random.random()<0.4: c[3]=random.choice([0.8,1.0,1.3,1.6])
    if random.random()<0.3: c[4]=random.choice([15,30,60])
    if random.random()<0.3: c[5]=random.choice([240,720,1440])
    if random.random()<0.4: c[6]=random.choice([60,120,240])
    if random.random()<0.4:
        h=set(c[7]); 
        if random.random()<0.5 and len(h)>2: h.discard(random.choice(list(h)))
        else: h.add(random.randrange(24))
        c[7]=tuple(sorted(h))
    if random.random()<0.3: c[8]=random.choice([0,0,3,5])
    return tuple(c)
random.seed(7); t0=time.time()
pop=[rand_cfg() for _ in range(16)]
best=(-1e9,None,None); hist=[]
for gen in range(25):
    scored=[]
    for c in pop:
        f,m=fit(c); scored.append((f,c,m))
    scored.sort(key=lambda x:-x[0])
    if scored[0][0]>best[0]: best=(scored[0][0],scored[0][1],scored[0][2])
    hist.append((gen,scored[0][0],scored[0][2]))
    print(f"gen {gen:>2}: fit={scored[0][0]:>8.2f} {scored[0][2]}",flush=True)
    elite=[c for _,c,_ in scored[:4]]
    pop=elite+[mutate(random.choice(elite)) for _ in range(12)]
print(f"\n=== BEST after {time.time()-t0:.0f}s: {best[2]} ===")
print(f"cfg={best[1]}")
# OOS validation on m3
a3=bt(D['m3'],best[1]); e=np.cumsum(a3); dd=abs((e-np.maximum.accumulate(e)).min())*0.01
print(f"OUT-OF-SAMPLE m3: n={len(a3)} net=${a3.sum()*0.01:.2f} WR={(a3>0).mean()*100:.1f}% DD=${dd:.2f}")
json.dump(dict(best=best[2],cfg=[list(best[1][7]),best[1][:7]+ (best[1][8],)]),open('evo.json','w'),default=str)
