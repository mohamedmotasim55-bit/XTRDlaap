import numpy as np, pandas as pd, itertools
P=0.01
CACHE={}
def prep(m):
    if m in CACHE: return CACHE[m]
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    bid=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/P
    ask=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/P
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=bid[last]; As=ask[last]
    bpm=60; nb=min(len(Bs),len(cnt))//bpm; B1=Bs[:nb*bpm]; ix=np.arange(0,nb*bpm,bpm)
    d=dict(u=u,B=Bs,A=As,
        hi=np.maximum.reduceat(B1,ix),lo=np.minimum.reduceat(B1,ix),cl=B1[bpm-1::bpm],
        cps=np.add.reduceat(cnt[:nb*bpm],ix),nb=nb)
    CACHE[m]=d; return d
def eng(m,L=60,EXITL=20,S=200,PULSE=1.5):
    d=prep(m); hi,lo,cl,cps,nb=d['hi'],d['lo'],d['cl'],d['cps'],d['nb']
    avg=pd.Series(cps).rolling(60).mean().values
    pos=0;ent=0.0;et=0;rec=[]
    for i in range(L,nb):
        if pos==0:
            brk=1 if cl[i]>hi[max(0,i-L):i].max() else (-1 if cl[i]<lo[max(0,i-L):i].min() else 0)
            if brk==0 or not (cps[i]>PULSE*np.nan_to_num(avg[i])): continue
            pos=brk; ent=cl[i]+13*brk; et=i
        else:
            pnl=None
            if pos>0:
                if cl[i]<=ent-S: pnl=-S
                elif cl[i]<lo[max(0,i-EXITL):i].min(): pnl=cl[i]-13-ent
            else:
                if cl[i]>=ent+S: pnl=-S
                elif cl[i]>hi[max(0,i-EXITL):i].max(): pnl=ent-(cl[i]+13)
            if pnl is not None: rec.append(pnl); pos=0
    return np.array(rec) if rec else np.array([])
def st(a):
    if len(a)==0: return None
    eq=np.cumsum(a); dd=(eq-np.maximum.accumulate(eq)).min()
    return dict(n=len(a),wr=(a>0).mean()*100,net=a.sum(),dd=dd,rf=a.sum()/abs(dd) if dd<0 else 0)
print("=== v3: وقف ثابت + نبض + قناة خروج — بحث على m3 ===")
print(f"{'L':>4}{'EXITL':>6}{'S':>5}{'PULSE':>6}{'n':>5}{'WR%':>6}{'net':>8}{'DD':>7}{'RF':>6}")
res=[]
for L,EXITL,S,PULSE in itertools.product([30,60,120],[15,20,30],[150,200,250],[1.2,1.5,2.0]):
    a=eng('m3',L,EXITL,S,PULSE); s=st(a)
    if not s or s['n']<20: continue
    res.append((L,EXITL,S,PULSE,s))
res.sort(key=lambda x:-x[4]['rf'])
for r in res[:12]:
    print(f"{r[0]:>4}{r[1]:>6}{r[2]:>5}{r[3]:>6.1f}{r[4]['n']:>5}{r[4]['wr']:>6.1f}{r[4]['net']:>8.0f}{r[4]['dd']:>7.0f}{r[4]['rf']:>6.2f}")
print("\n=== أفضل 5 إعدادات على m1 و m2 (التحقق) ===")
for r in res[:5]:
    out=[]
    for m in ['m1','m2']:
        s=st(eng(m,r[0],r[1],r[2],r[3]))
        out.append(f"{m}: net {s['net']:+.0f} RF {s['rf']:.1f}" if s else f"{m}: -")
    print(f"  L={r[0]} EXITL={r[1]} S={r[2]} P={r[3]:.1f} | m3 net {r[4]['net']:+.0f} | " + " | ".join(out))
