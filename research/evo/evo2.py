import numpy as np, random, json, time
from harness import load
D={m:load(m) for m in ['m1','m2','m3']}
def bt(d,cfg):
    aT,bS,mode,pulse_th,chlen,trendlen,hold,hours,atr_gate,trail=cfg
    bcl,acl,bhi,blo,ahi,alo,vol,volavg,nb=d['bcl'],d['acl'],d['bhi'],d['blo'],d['ahi'],d['alo'],d['vol'],d['volavg'],d['nb']
    atr=d['rngavg']; hr=((d['t']%86400)//3600); pnls=[]; last=-1
    hm=np.isin(hr,hours) if hours else np.ones(nb,bool)
    gate=(atr>=atr_gate*(acl-bcl)) if atr_gate>0 else np.ones(nb,bool)
    for i in range(max(chlen,trendlen)+1,nb-hold-1):
        if i<=last or not hm[i] or not gate[i]: continue
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
        tgt=aT*A; stp=bS*A; trl=trail*A
        ent=acl[i-1] if dr>0 else bcl[i-1]; k=min(i+hold,nb-1); pnl=None; mfe=0.0
        for j in range(i,k+1):
            fav=(bcl[j]-ent) if dr>0 else (ent-acl[j])
            if fav>mfe: mfe=fav
            if dr>0:
                if blo[j]<=ent-stp: pnl=-stp; break
                if tgt and bhi[j]>=ent+tgt: pnl=tgt; break
            else:
                if ahi[j]>=ent+stp: pnl=-stp; break
                if tgt and alo[j]<=ent-tgt: pnl=tgt; break
            if trl and mfe>=trl and (mfe-fav)>=trl*0.4: pnl=fav; break
        if pnl is None: pnl=(bcl[k]-ent) if dr>0 else (ent-acl[k])
        pnls.append(pnl); last=k
    return np.array(pnls)
def fit(cfg):
    a1=bt(D['m1'],cfg); a2=bt(D['m2'],cfg); a=np.concatenate([a1,a2])
    if len(a)<25: return -1e9,None
    net=a.sum()*0.01; e=np.cumsum(a); dd=abs((e-np.maximum.accumulate(e)).min())*0.01
    return net-0.6*dd, dict(net=net,dd=dd,wr=(a>0).mean()*100,n=len(a))
def rand_cfg():
    return (random.choice([2,3,4,5,6,8]), random.choice([1,1.5,2,2.5,3,4]),
            random.choice(['pullback','fade']), random.choice([0.8,1.0,1.2,1.4,1.6]),
            random.choice([10,15,20,30,45,60]), random.choice([240,480,720,1440]),
            random.choice([60,120,180,240,300]),
            tuple(sorted(random.sample(range(24),random.choice([4,5,6,8,12,24])))),
            random.choice([0,2,3,4,6]), random.choice([0,0,2,3,4]))
def mutate(c):
    c=list(c)
    for k,vals in [(0,[2,3,4,5,6,8]),(1,[1,1.5,2,2.5,3,4]),(2,['pullback','fade']),
                   (3,[0.8,1.0,1.2,1.4,1.6]),(4,[10,15,20,30,45,60]),(5,[240,480,720,1440]),
                   (6,[60,120,180,240,300]),(8,[0,2,3,4,6]),(9,[0,0,2,3,4])]:
        if random.random()<0.35: c[k]=random.choice(vals)
    if random.random()<0.5:
        h=set(c[7])
        if random.random()<0.5 and len(h)>3: h.discard(random.choice(list(h)))
        else: h.add(random.randrange(24))
        c[7]=tuple(sorted(h))
    return tuple(c)
random.seed(11); t0=time.time(); POP=24; GENS=200
pop=[rand_cfg() for _ in range(POP)]; best=(-1e9,None,None)
for gen in range(GENS):
    scored=[]
    for c in pop:
        f,m=fit(c); scored.append((f,c,m))
    scored.sort(key=lambda x:-x[0])
    if scored[0][0]>best[0]: best=(scored[0][0],scored[0][1],scored[0][2])
    if gen%20==0 or gen==GENS-1:
        print(f"gen {gen:>3}: fit={scored[0][0]:>8.2f} net=${scored[0][2]['net']:.1f} dd=${scored[0][2]['dd']:.1f} wr={scored[0][2]['wr']:.1f}% n={scored[0][2]['n']}",flush=True)
    elite=[c for _,c,_ in scored[:6]]
    pop=elite+[mutate(random.choice(elite)) for _ in range(POP-6)]
print(f"\n=== BEST ({POP*GENS} evals in {time.time()-t0:.0f}s): {best[2]} ===")
print(f"cfg={best[1]}")
print("\n--- per month ---")
for m in ['m1','m2','m3']:
    a=bt(D[m],best[1]); e=np.cumsum(a); dd=abs((e-np.maximum.accumulate(e)).min())*0.01
    print(f"  {m}: n={len(a)} net=${a.sum()*0.01:.2f} WR={(a>0).mean()*100:.1f}% DD=${dd:.2f} {'✅' if a.sum()>0 else '❌'}")
json.dump(dict(cfg=[str(best[1])],m=best[2]),open('evo2.json','w'),default=str)
