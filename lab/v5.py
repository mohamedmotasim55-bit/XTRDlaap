import numpy as np, pandas as pd, itertools, json
exec(open('v3.py').read().split('print("=== v3')[0])
def eng5(m,L1=30,L2=0,EXITL=20,S=120,PULSE=1.2,BE=0,TRAIL=0,SESS=0):
    d=prep(m); hi,lo,cl,cps,nb,u=d['hi'],d['lo'],d['cl'],d['cps'],d['nb'],d['u']
    avg=pd.Series(cps).rolling(60).mean().values
    ixh=((u[np.arange(0,nb*60,60)]%86400)//3600) if len(u)>=nb*60 else np.zeros(nb)
    pos=0;ent=0.0;stop=0.0;best=0.0;rec=[]
    for i in range(max(L1,L2),nb):
        if pos==0:
            up=cl[i]>hi[max(0,i-L1):i].max(); dn=cl[i]<lo[max(0,i-L1):i].min()
            if L2>0:
                up=up or cl[i]>hi[max(0,i-L2):i].max(); dn=dn or cl[i]<lo[max(0,i-L2):i].min()
            brk=1 if up else (-1 if dn else 0)
            if brk==0: continue
            if PULSE>0 and not (cps[i]>PULSE*np.nan_to_num(avg[i])): continue
            if SESS and int(ixh[i]) in (23,0,1): continue
            pos=brk; ent=cl[i]+13*brk; stop=ent-S*brk; best=ent
        else:
            pnl=None
            if pos>0:
                best=max(best,cl[i]); prof=best-ent
                if BE>0 and prof>=BE: stop=max(stop,ent)
                if TRAIL>0 and prof>=BE: stop=max(stop,best-TRAIL)
                if cl[i]<=stop: pnl=stop-ent
                elif cl[i]<lo[max(0,i-EXITL):i].min(): pnl=cl[i]-13-ent
            else:
                best=min(best,cl[i]); prof=ent-best
                if BE>0 and prof>=BE: stop=min(stop,ent)
                if TRAIL>0 and prof>=BE: stop=min(stop,best+TRAIL)
                if cl[i]>=stop: pnl=ent-stop
                elif cl[i]>hi[max(0,i-EXITL):i].max(): pnl=ent-(cl[i]+13)
            if pnl is not None: rec.append(pnl); pos=0
    return np.array(rec) if rec else np.array([])
def st5(a):
    if len(a)<10: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 99)
grid=[]
for L2 in [0,60]:
    for EXITL in [10,15,20,30]:
        for S in [100,120,150]:
            for BE,TR in [(0,0),(100,0),(100,80),(150,100)]:
                grid.append(dict(L1=30,L2=L2,EXITL=EXITL,S=S,PULSE=1.2,BE=BE,TRAIL=TR))
print(f"تركيبات: {len(grid)}",flush=True)
res=[]
for k,g in enumerate(grid):
    nets=[]
    for m in ['m1','m2','m3']:
        s=st5(eng5(m,**g))
        if not s: nets=None; break
        nets.append((s['net'],s['rf'],s['n']))
    if nets is None: continue
    res.append((g,nets))
res.sort(key=lambda x:-min(n[0] for n in x[1]))
print(f"\n{'L2':>4}{'EXIT':>5}{'S':>5}{'BE':>5}{'TR':>5}{'m1':>8}{'m2':>8}{'m3':>8}{'أسوأ':>8}{'RFmin':>6}{'صفقات':>7}")
for g,n in res[:15]:
    print(f"{g['L2']:>4}{g['EXITL']:>5}{g['S']:>5}{g['BE']:>5}{g['TRAIL']:>5}{n[0][0]:>8.0f}{n[1][0]:>8.0f}{n[2][0]:>8.0f}{min(x[0] for x in n):>8.0f}{min(x[1] for x in n):>6.1f}{sum(x[2] for x in n):>7}",flush=True)
json.dump([(g,[list(x) for x in n]) for g,n in res[:20]],open('v5_top.json','w'))
