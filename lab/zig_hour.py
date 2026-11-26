import numpy as np
print("=== الزجزاج الحيّ لكل ساعة (X=150,200) ===")
msc=np.load('/home/openhands/data/m1_msc.npy')
B=np.load('/home/openhands/data/m1_bid.npy').astype(np.float64)/0.01
A=np.load('/home/openhands/data/m1_ask.npy').astype(np.float64)/0.01
sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
B=B[last]; A=A[last]; hr=((u%86400)//3600); n=len(B)
for X in [100,200,300]:
    print(f"\n--- X={X} ---")
    for H in range(24):
        sel=hr==H
        if sel.sum()<10000: continue
        pos=1; ent=None; extreme=None; pnls=[]
        idx=np.where(sel)[0]
        # reset per hour block: run zigzag only within this hour's seconds
        start=idx[0]
        pos=1; ent=A[start]; extreme=B[start]
        for i in idx[1:]:
            if pos>0:
                if B[i]>extreme: extreme=B[i]
                elif extreme-B[i]>=X:
                    pnls.append(B[i]-ent); pos=-1; ent=B[i]; extreme=B[i]
            else:
                if A[i]<extreme: extreme=A[i]
                elif A[i]-extreme>=X:
                    pnls.append(ent-A[i]); pos=1; ent=A[i]; extreme=A[i]
        if len(pnls)<20: continue
        a=np.array(pnls)
        if a.sum()>0:
            print(f"  ساعة {H:>2}: n={len(a):>5} متوسط={a.mean():>7.1f} صافي={a.sum():>8.0f} WR={ (a>0).mean()*100:>4.1f}% ✅")
    print("  (لم تُطبع الساعات الخاسرة)")
