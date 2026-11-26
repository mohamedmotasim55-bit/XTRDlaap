import numpy as np, pandas as pd
from texit import prep
def trades(m,HOLD=45,S=35,EXT=50,COOL=5,HOURS=(1,)):
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,nb,day,hr=d['bhi'],d['blo'],d['bcl'],d['ahi'],d['alo'],d['acl'],d['nb'],d['day'],d['hour']
    atr=pd.Series(bhi-blo).rolling(60).mean().values
    pos=0;ent=0.0;stop=0.0;rec=[];last_exit=-10**9;et=0
    for i in range(41,nb):
        if pos==0:
            if i-last_exit<COOL or hr[i] not in HOURS: continue
            hh=bhi[i-41:i-1].max(); ll=blo[i-41:i-1].min()
            if bcl[i-1]>hh+EXT:   pos=-1; ent=bcl[i-1]; stop=ent+S
            elif bcl[i-1]<ll-EXT: pos=1; ent=acl[i-1]; stop=ent-S
            else: continue
            et=i; dr=pos
            ctx=dict(m=m,i=i,hour=int(hr[i]),mag=(bcl[i-1]-hh) if pos<0 else (ll-bcl[i-1]),
                     atr=atr[i-1] if not np.isnan(atr[i-1]) else 0,
                     ticks=0)
        if pos!=0:
            pnl=None; why=None
            if pos>0:
                if blo[i]<=stop: pnl=stop-ent; why='stop'
                elif i-et>=HOLD: pnl=bcl[i]-ent; why='time'
            else:
                if ahi[i]>=stop: pnl=ent-stop; why='stop'
                elif i-et>=HOLD: pnl=ent-acl[i]; why='time'
            if pnl is not None:
                j45=min(et+45,nb-1); j10=min(et+10,nb-1); j90=min(et+90,nb-1)
                # continuation profit if we had FOLLOWED breakout instead of fading = -pnl proxy
                ctx2={**ctx,'pnl':pnl,'why':why,'bars_held':i-et,
                      'cont10':-((bcl[j10]-bcl[et])*dr),'cont45':-((bcl[j45]-bcl[et])*dr),
                      'cont90':-((bcl[j90]-bcl[et])*dr),
                      'mfe':(max(bhi[et:i+1])-bcl[et]) if dr<0 else (bcl[et]-min(blo[et:i+1]))}
                rec.append(ctx2); pos=0; last_exit=i
    return pd.DataFrame(rec)
T=pd.concat([trades(m) for m in ['m1','m2','m3']],ignore_index=True)
L=T[T.pnl<=0]; W=T[T.pnl>0]
print(f"إجمالي {len(T)} | رابحة {len(W)} | خاسرة {len(L)}")
print(f"\n=== الخسائر: كيف انتهت ===")
print(L.why.value_counts().to_string())
print(f"\n=== الخسائر: مدة الصفقة (دقيقة) ===")
print(L.bars_held.describe().round(1).to_string())
print(f"\n=== لو كنا تابعنا الاتجاه بدل الارتداد (نقاط) ===")
print(f"  على الخسائر: cont10={L.cont10.mean():+.0f} cont45={L.cont45.mean():+.0f} cont90={L.cont90.mean():+.0f}")
print(f"  نسبة خسائر كان استمرارها > 26: {(L.cont45>26).mean()*100:.1f}%")
print(f"\n=== الخسائر حسب حجم الاختراق ===")
L2=L.copy(); L2['mb']=pd.qcut(L2.mag,3,labels=['50-80','80-150','150+'],duplicates='drop')
print(L2.groupby('mb',observed=True).agg(n=('pnl','size'),avg_loss=('pnl','mean'),cont45=('cont45','mean'),cont_mfe=('mfe','mean')).round(0).to_string())
print(f"\n=== الخسائر حسب ATR ===")
L2['ab']=pd.qcut(L2.atr,3,labels=['هادئ','عادي','نشط'],duplicates='drop')
print(L2.groupby('ab',observed=True).agg(n=('pnl','size'),avg_loss=('pnl','mean'),cont45=('cont45','mean')).round(0).to_string())
print(f"\n=== الخسائر: هل الوقف كان قريبًا جدًا؟ (MFE قبل الوقف) ===")
print(f"  متوسط أفضل حركة في اتجاهنا قبل الوقف: {L.mfe.mean():.0f} نقطة")
print(f"  نسبة الخسائر التي بلغت +20 قبل الوقف: {(L.mfe>20).mean()*100:.1f}%")
print(f"  نسبة الخسائر التي بلغت +35 قبل الوقف: {(L.mfe>35).mean()*100:.1f}%")
T.to_csv('forensic_trades.csv',index=False)
