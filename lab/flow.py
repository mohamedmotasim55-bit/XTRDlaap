import numpy as np
print("=== 1) تدفق التكات (Order Flow) — اتجاه كل تكة ===")
msc=np.load('/home/openhands/data/m1_msc.npy')
B=np.load('/home/openhands/data/m1_bid.npy').astype(np.float64)/0.01
A=np.load('/home/openhands/data/m1_ask.npy').astype(np.float64)/0.01
sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
Bs=B[last]; As=A[last]
# per-second last price and up/down tick counts
up=np.zeros(len(u)); dn=np.zeros(len(u))
d=np.sign(np.diff(B))
d=np.insert(d,0,0)
np.add.at(up, np.searchsorted(u,sec), (d>0).astype(float))
np.add.at(dn, np.searchsorted(u,sec), (d<0).astype(float))
Bsec=Bs; n=len(u)
print(f"ثواني {n:,}")
for W in [5,10,30]:
    imb=np.convolve(up-dn,np.ones(W),'full')[:n]
    fwd=Bsec[W+30:]-Bsec[W:-30] if W+30<n else None
    L=min(len(imb),len(fwd)); imb=imb[:L]; fwd=fwd[:L]
    for TH in [5,10,20]:
        sel=imb>TH
        if sel.sum()>5000:
            print(f"  W={W}s imb>{TH:2d}: n={sel.sum():7d} متوسط fwd30={fwd[sel].mean():+6.1f} net>0={(fwd[sel]>26).mean()*100:4.1f}% ضد={(fwd[sel]<-26).mean()*100:4.1f}%")
    print()
print("=== 2) توسع السبريد (فجوة سيولة) ===")
sp=As-Bs
spavg=np.convolve(sp,np.ones(60)/60,'full')[:n]
for mult in [1.5,2.0,3.0]:
    sel=sp>spavg*mult
    if sel.sum()>1000:
        f=Bsec[30:]-Bsec[:-30]; L=min(len(f),n); f=f[:L]; s=sel[:L]
        print(f"  spread>{mult}x avg: n={s.sum():6d} متوسط fwd30={f[s].mean():+6.1f} | يكمل>26={(f[s]>26).mean()*100:4.1f}% | يرتد>26={(f[s]<-26).mean()*100:4.1f}%")
