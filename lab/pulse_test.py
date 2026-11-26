import numpy as np
print("=== هل النبض يتنبأ؟ (اختبار مباشر) ===")
msc=np.load('/home/openhands/data/m1_msc.npy')
B=np.load('/home/openhands/data/m1_bid.npy').astype(np.float64)/0.01
sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
B=B[last]; n=len(u)
cnt=np.zeros(n); np.add.at(cnt,np.searchsorted(u,sec),1.0)  # ticks per second
pulse=np.convolve(cnt,np.ones(5),'full')[:n]                # ticks last 5s
pavg=np.convolve(cnt,np.ones(300)/300,'full')[:n]           # avg 5min
pr=np.where(pavg>0,pulse/pavg,1.0)
fwd=np.zeros(n); fwd[:-30]=B[30:]-B[:-30]
absfwd=np.abs(fwd)
# 1) pulse -> volatility (abs move)?
m=pr>0.1
print(f"1) النبض → التقلب (|حركة 30s|):")
for lo,hi in [(0,0.5),(0.5,1),(1,2),(2,4),(4,99)]:
    s=m&(pr>=lo)&(pr<hi)
    if s.sum()>1000: print(f"   نبض {lo}-{hi}x: n={s.sum():7d} متوسط |حركة|={absfwd[s].mean():6.1f}")
# 2) pulse -> direction?
print(f"2) النبض → الاتجاه (نسبة صعود):")
for lo,hi in [(0,0.5),(0.5,1),(1,2),(2,4),(4,99)]:
    s=m&(pr>=lo)&(pr<hi)
    if s.sum()>1000: print(f"   نبض {lo}-{hi}x: صعود={ (fwd[s]>0).mean()*100:4.1f}% | >26ن={(fwd[s]>26).mean()*100:4.1f}% | <−26ن={(fwd[s]<-26).mean()*100:4.1f}%")
# 3) pulse + momentum combo
print(f"3) نبض عالٍ + زخم (آخر 10s) → هل يكمل؟")
mom=B-np.roll(B,10); mom[:10]=0
for prth in [1.5,2.0,3.0]:
    for mth in [20,40]:
        s=m&(pr>=prth)&(mom>mth)
        if s.sum()>500:
            print(f"   نبض>{prth} + زخم>{mth}: n={s.sum():6d} | يكمل>26={(fwd[s]>26).mean()*100:4.1f}% | متوسط={fwd[s].mean():+6.1f}")
