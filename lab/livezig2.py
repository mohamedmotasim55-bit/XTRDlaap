import numpy as np
print("=== الزجزاج الحيّ — حساب صحيح (شراء ask · بيع bid) ===")
msc=np.load('/home/openhands/data/m1_msc.npy')
B=np.load('/home/openhands/data/m1_bid.npy').astype(np.float64)/0.01
A=np.load('/home/openhands/data/m1_ask.npy').astype(np.float64)/0.01
sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
B=B[last]; A=A[last]; nd=len(np.unique(u//86400)); n=len(B)
print(f"{'X':>5}{'صفقات':>8}{'/يوم':>6}{'متوسط':>8}{'صافي':>10}{'$':>9}{'WR%':>6}{'DD$':>7}")
for X in [30,50,100,150,200,300,400]:
    pos=1; ent=A[0]; extreme=B[0]; pnls=[]
    for i in range(1,n):
        if pos>0:
            if B[i]>extreme: extreme=B[i]
            elif extreme-B[i]>=X:
                pnls.append(B[i]-ent)          # close long: sell at bid
                pos=-1; ent=B[i]; extreme=B[i] # open short: sell at bid
        else:
            if A[i]<extreme: extreme=A[i]
            elif A[i]-extreme>=X:
                pnls.append(ent-A[i])          # close short: buy at ask
                pos=1; ent=A[i]; extreme=A[i]  # open long: buy at ask
    a=np.array(pnls)
    if len(a)==0: continue
    e=np.cumsum(a); dd=(e-np.maximum.accumulate(e)).min()
    print(f"{X:>5}{len(a):>8}{len(a)/nd:>6.0f}{a.mean():>8.1f}{a.sum():>10.0f}{a.sum()*0.01:>9.0f}{(a>0).mean()*100:>6.1f}{abs(dd)*0.01:>7.0f}",flush=True)
