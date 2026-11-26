import numpy as np
print("=== الزجزاج الحيّ: اقلب الصفقة عند ارتداد X — اقتناص كل تأرجح ===")
msc=np.load('/home/openhands/data/m1_msc.npy')
B=np.load('/home/openhands/data/m1_bid.npy').astype(np.float64)/0.01
A=np.load('/home/openhands/data/m1_ask.npy').astype(np.float64)/0.01
sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
B=B[last]; A=A[last]; nd=len(np.unique(u//86400)); n=len(B)
print(f"{'X':>5}{'flips':>7}{'/يوم':>6}{'متوسط سعة':>10}{'صافي/صفقة':>10}{'صافي شهر':>10}{'$':>9}{'WR%':>6}")
for X in [50,100,150,200,300,400]:
    pos=1; ent=A[0]; extreme=B[0]; flips=[]; 
    for i in range(1,n):
        if pos>0:
            if B[i]>extreme: extreme=B[i]
            elif extreme-B[i]>=X:
                flips.append((ent,A[i],B[i])); ent=A[i]; pos=-1; extreme=B[i]
        else:
            if A[i]<extreme: extreme=A[i]
            elif A[i]-extreme>=X:
                flips.append((ent,B[i],A[i])); ent=B[i]; pos=1; extreme=A[i]
    pnls=[]
    for j in range(0,len(flips)-1):
        ent_p=flips[j][1]; nxt=flips[j+1][1]
        # long: exit at next flip's bid; short: exit at next flip's ask
        if j%2==0: pnls.append(nxt-ent_p)  # approximation
        else: pnls.append(ent_p-nxt)
    if not pnls: continue
    a=np.array(pnls); e=np.cumsum(a); dd=(e-np.maximum.accumulate(e)).min()
    print(f"{X:>5}{len(flips):>7}{len(flips)/nd:>6.0f}{X:>10}{a.mean():>10.1f}{a.sum():>10.0f}{a.sum()*0.01:>9.0f}{(a>0).mean()*100:>6.1f}",flush=True)
