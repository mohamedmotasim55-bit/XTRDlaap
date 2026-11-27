import numpy as np
HOURS=[6,13,17,20,21]
def zig(m,X,HOURS):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    A=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    B=B[last]; A=A[last]; hr=((u%86400)//3600); nd=len(np.unique(u//86400))
    pnls=[]
    for H in HOURS:
        idx=np.where(hr==H)[0]
        if len(idx)<100: continue
        pos=1; ent=A[idx[0]]; extreme=B[idx[0]]
        for i in idx[1:]:
            if pos>0:
                if B[i]>extreme: extreme=B[i]
                elif extreme-B[i]>=X: pnls.append(B[i]-ent); pos=-1; ent=B[i]; extreme=B[i]
            else:
                if A[i]<extreme: extreme=A[i]
                elif A[i]-extreme>=X: pnls.append(ent-A[i]); pos=1; ent=A[i]; extreme=A[i]
    a=np.array(pnls)
    return a,nd
print("=== التحقق خارج العينة: الزجزاج X=200 على الساعات {6,13,17,20,21} ===")
for m in ['m1','m2','m3']:
    a,nd=zig(m,200,HOURS)
    e=np.cumsum(a); dd=(e-np.maximum.accumulate(e)).min()
    print(f"  {m}: n={len(a):>5} متوسط={a.mean():>7.1f} صافي={a.sum():>8.0f} = ${a.sum()*0.01:>7.0f} WR={(a>0).mean()*100:>4.1f}% DD=${abs(dd)*0.01:.0f} /يوم={len(a)/nd:.0f}")
print("\n=== X=300 ===")
for m in ['m1','m2','m3']:
    a,nd=zig(m,300,HOURS)
    e=np.cumsum(a); dd=(e-np.maximum.accumulate(e)).min()
    print(f"  {m}: n={len(a):>5} متوسط={a.mean():>7.1f} صافي={a.sum():>8.0f} = ${a.sum()*0.01:>7.0f} WR={(a>0).mean()*100:>4.1f}% DD=${abs(dd)*0.01:.0f} /يوم={len(a)/nd:.0f}")
