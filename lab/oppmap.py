import numpy as np, pandas as pd
from ddctl import prep
rows=[]
for m in ['m1','m2','m3']:
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,nb,day,hr=d['bhi'],d['blo'],d['bcl'],d['ahi'],d['alo'],d['acl'],d['nb'],d['day'],d['hour']
    L1=40
    for i in range(L1+1,nb):
        hh=bhi[i-1-L1:i-1].max(); ll=blo[i-1-L1:i-1].min()
        if bcl[i-1]>hh+50: dr,mag=-1,bcl[i-1]-hh
        elif bcl[i-1]<ll-50: dr,mag=1,ll-bcl[i-1]
        else: continue
        r={}
        for hz in [5,10,20,60,120]:
            j=i+hz
            if j<nb: r[f'r{hz}']=(bcl[i]-bcl[j])*dr
        if len(r)==5: rows.append(dict(m=m,hour=int(hr[i]),mag=mag,dr=dr,**r))
T=pd.DataFrame(rows)
print(f"عدد الاختراقات الضخمة: {len(T)}")
g=T.groupby('hour').agg(n=('r5','size'),r5=('r5','mean'),r10=('r10','mean'),r20=('r20','mean'),r60=('r60','mean'),r120=('r120','mean'))
print("\n=== متوسط الارتداد (نقاط) ===")
print(g.round(0).to_string())
h=T.groupby('hour').agg(n=('r20','size'),p20=('r20',lambda x:(x>26).mean()*100),p60=('r60',lambda x:(x>26).mean()*100))
print("\n=== نسبة ارتداد > 26 ===")
print(h.round(1).to_string())
print("\n=== حسب حجم الاختراق ===")
T['mb']=pd.qcut(T.mag,3,labels=['50-100','100-200','200+'],duplicates='drop')
print(T.groupby('mb',observed=True).agg(n=('r20','size'),r20=('r20','mean'),r60=('r60','mean')).round(0).to_string())
