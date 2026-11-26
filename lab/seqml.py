import numpy as np, pandas as pd
def feats(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    B=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    A=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    Bs=B[last]; As=A[last]
    df=pd.DataFrame({'b':Bs,'a':As,'c':cnt})
    df['r1']=df.b.diff(1)
    df['sp']=df.a-df.b
    # lagged returns 1..60
    for k in [1,2,3,5,10,20,30,45,60,90,120]:
        df[f'l{k}']=df.r1.shift(k)
    df['vol']=df.r1.rolling(60).std()
    df['cps']=df.c.rolling(60).mean()
    df['cpsr']=df.c/df.cps
    df['pctB']=(df.b-df.b.rolling(60).min())/(df.b.rolling(60).max()-df.b.rolling(60).min()+1e-9)
    # triple barrier: first hit +T or -S within H
    H=30; T=40; S=40
    fwd_max=df.b[::-1].rolling(H,min_periods=1).max()[::-1].shift(-1)-df.b
    fwd_min=df.b[::-1].rolling(H,min_periods=1).min()[::-1].shift(-1)-df.b
    # label: +1 if +T hit before -S
    up_first=(fwd_max>=T)
    dn_first=(fwd_min<=-S)
    lab=np.where(up_first&~dn_first,1,np.where(dn_first&~up_first,-1,0))
    df['lab']=lab
    return df
cols=['r1','sp','l1','l2','l3','l5','l10','l20','l30','l45','l60','l90','l120','vol','cpsr','pctB']
print("=== نموذج تسلسلي: هل يمكن التنبؤ بالحاجز؟ ===")
tr=pd.concat([feats('m1'),feats('m2')]).dropna()
te=feats('m3').dropna()
tr=tr[tr.lab!=0]; te2=te[te.lab!=0]
print(f"تدريب {len(tr):,} | اختبار {len(te2):,}")
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score
m=HistGradientBoostingClassifier(max_iter=300,max_depth=8,learning_rate=0.05,random_state=1)
m.fit(tr[cols],(tr.lab>0).astype(int))
p=m.predict_proba(te2[cols])[:,1]
auc=roc_auc_score((te2.lab>0).astype(int),p)
print(f"AUC = {auc:.4f}")
for q in [50,80,90,95,99]:
    thr=np.percentile(p,q); sel=p>=thr
    wr=(te2.lab[sel]>0).mean()*100
    print(f"  أعلى {100-q:>2}% ثقة: n={sel.sum():5d} نسبة فوز الحاجز={wr:.1f}%")
