import numpy as np
print("=== عدّ الصفقات الرابحة الحقيقية في شهر واحد (زجزاج السوق) ===")
print("كل تأرجح > X نقطة = صفقة رابحة واحدة ممكنة")
for m in ['m1']:
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    B=B[last]; nd=len(np.unique(u//86400))
    print(f"\n{m}: {nd} يوم | {len(B):,} ثانية")
    for X in [26,50,100,200,400]:
        # zigzag with threshold X
        dirn=0; ext=B[0]; cnt=0; amp=0.0; start=0
        for i in range(1,len(B)):
            p=B[i]
            if dirn>=0:
                if p>ext: ext=p
                elif ext-p>=X:
                    if dirn==1: cnt+=1; amp+=(ext-B[start]) if start else 0
                    dirn=-1; ext=p; start=i
            if dirn<=0:
                if p<ext: ext=p
                elif p-ext>=X:
                    if dirn==-1: cnt+=1
                    dirn=1; ext=p; start=i
        print(f"  تأرجح ≥{X:>3}ن: {cnt:>6} صفقة/شهر = {cnt/nd:>5.0f}/يوم")
print("\n=== الحد الأقصى للربح (مجموع سعة التأرجحات) ===")
msc=np.load('/home/openhands/data/m1_msc.npy')
B=np.load('/home/openhands/data/m1_bid.npy').astype(np.float64)/0.01
sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
B=B[last]
for X in [50,100,200]:
    dirn=0; ext=B[0]; amp=0.0; cnt=0
    for i in range(1,len(B)):
        p=B[i]
        if dirn>=0:
            if p>ext: ext=p
            elif ext-p>=X:
                if dirn==1: cnt+=1
                dirn=-1; ext=p
        if dirn<=0:
            if p<ext: ext=p
            elif p-ext>=X:
                if dirn==-1: cnt+=1
                dirn=1; ext=p
    print(f"  عتبة {X}: {cnt} صفقة × متوسط {X} = {cnt*X:,.0f} نقطة = {cnt*X*0.01:,.0f}$ (0.01 لوت)")
