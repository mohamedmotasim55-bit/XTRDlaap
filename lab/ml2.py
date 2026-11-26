import numpy as np, pandas as pd
def feats(m):
    msc=np.load(f'/home/openhands/data/{m}_msc.npy')
    bid=np.load(f'/home/openhands/data/{m}_bid.npy').astype(np.float64)/0.01
    ask=np.load(f'/home/openhands/data/{m}_ask.npy').astype(np.float64)/0.01
    sec=msc//1000; u=np.unique(sec); last=np.searchsorted(sec,u,side='right')-1
    first=np.searchsorted(sec,u,side='left'); cnt=np.diff(np.append(first,len(sec)))
    B=bid[last]; A=ask[last]; nb=len(B)//60; N=nb*60; ix=np.arange(0,N,60)
    bcl=B[59:N:60]; acl=A[59:N:60]; bhi=np.maximum.reduceat(B[:N],ix); blo=np.minimum.reduceat(B[:N],ix)
    spread=(acl-bcl); cps=np.add.reduceat(cnt[:N],ix)
    hour=((u[ix]%86400)//3600); dow=((u[ix]//86400)+4)%7
    df=pd.DataFrame({'bcl':bcl,'bhi':bhi,'blo':blo,'spread':spread,'cps':cps,'hour':hour,'dow':dow})
    df['ret1']=df.bcl.diff(1); df['ret5']=df.bcl.diff(5); df['ret15']=df.bcl.diff(15)
    df['ret60']=df.bcl.diff(60); df['ret240']=df.bcl.diff(240)
    df['atr']=(df.bhi-df.blo).rolling(60).mean()
    df['rv']=df.ret1.rolling(60).std()
    df['ma60']=df.bcl.rolling(60).mean(); df['dist_ma']=df.bcl-df.ma60
    hh=df.bhi.rolling(60).max(); ll=df.blo.rolling(60).min()
    df['pctB']=(df.bcl-ll)/(hh-ll+1e-9)
    df['cps_ratio']=df.cps/df.cps.rolling(60).mean()
    df['spread_ratio']=df.spread/df.spread.rolling(60).mean()
    df['zscore']=df.dist_ma/(df.rv*20+1e-9)
    df['vol_ratio']=df.rv/df.rv.rolling(240).mean()
    for h in [5,15,30,60]:
        df[f'fwd{h}']=df.bcl.shift(-h)-df.bcl
    return df
cols=['ret1','ret5','ret15','ret60','ret240','atr','rv','dist_ma','pctB','cps_ratio','spread_ratio','zscore','vol_ratio','hour','dow']
tr=pd.concat([feats('m1'),feats('m2')]).dropna()
te=feats('m3').dropna()
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score
print("=== نموذج التنبؤ بالاتجاه (تدريب m1+m2 · اختبار m3) ===")
for H in [5,15,30,60]:
    ytr=(tr[f'fwd{H}']>0).astype(int); yte=(te[f'fwd{H}']>0).astype(int)
    m=HistGradientBoostingClassifier(max_iter=200,max_depth=6,learning_rate=0.05,random_state=1)
    m.fit(tr[cols],ytr)
    p=m.predict_proba(te[cols])[:,1]
    auc=roc_auc_score(yte,p)
    # trade sim: top 20% confidence only
    thr=np.percentile(p,80)
    sel=p>=thr
    actual=te[f'fwd{H}'][sel]
    print(f"  أفق {H:>2}د: AUC={auc:.4f} | إشارات قوية 20%: {sel.sum()} | متوسط حركة {actual.mean():+.0f} نقطة",flush=True)
