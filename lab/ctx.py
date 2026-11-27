import numpy as np, pandas as pd
from ddctl import prep
def trades(m,L1=40,EXITL=4,S=35,COOL=10,DL=3):
    d=prep(m); bhi,blo,bcl,ahi,alo,acl,nb,day,hr=d['bhi'],d['blo'],d['bcl'],d['ahi'],d['alo'],d['acl'],d['nb'],d['day'],d['hour']
    atr=pd.Series(bhi-blo).rolling(60).mean().values
    ret240=np.concatenate([np.zeros(240),bcl[240:]-bcl[:-240]]) if nb>240 else np.zeros(nb)
    pos=0;ent=0.0;stop=0.0;rec=[];last_exit=-10**9;et=0;cur=-1;dn_=0;blocked=False
    for i in range(L1+1,nb):
        if day[i]!=cur: cur=day[i]; dn_=0; blocked=False
        if pos==0:
            if blocked or i-last_exit<COOL: continue
            hh=bhi[i-1-L1:i-1].max(); ll=blo[i-1-L1:i-1].min()
            if bcl[i-1]>hh:   pos=-1; ent=bcl[i-1]; stop=ent+S
            elif bcl[i-1]<ll: pos=1; ent=acl[i-1]; stop=ent-S
            else: continue
            et=i; ext=(bcl[et-1]-hh) if pos<0 else (ll-bcl[et-1])
            ctx=dict(hour=int(hr[i]),ext=ext,atr=atr[i-1] if not np.isnan(atr[i-1]) else 0,
                     trend=int(np.sign(ret240[i-1])),side='SELL' if pos<0 else 'BUY')
        if pos!=0:
            pnl=None
            if pos>0:
                if blo[i]<=stop: pnl=stop-ent
                elif i>et and bcl[i]<blo[max(0,i-EXITL):i].min(): pnl=bcl[i]-ent
            else:
                if ahi[i]>=stop: pnl=ent-stop
                elif i>et and acl[i]>ahi[max(0,i-EXITL):i].max(): pnl=ent-acl[i]
            if pnl is not None:
                rec.append({**ctx,'pnl':pnl,'month':m}); pos=0; last_exit=i
                if pnl<0: dn_+=1
                if DL>0 and dn_>=DL: blocked=True
    return pd.DataFrame(rec)
T=pd.concat([trades(m) for m in ['m1','m2','m3']],ignore_index=True)
T['win']=T.pnl>0
print(f"إجمالي {len(T)} صفقة | فوز {T.win.mean()*100:.1f}% | صافي {T.pnl.sum():+.0f}")
print("\n=== حسب الساعة (UTC) ===")
h=T.groupby('hour').agg(n=('pnl','size'),wr=('win','mean'),net=('pnl','sum'),avg=('pnl','mean'))
h['wr']*=100
print(h[h.n>=5].to_string())
print("\n=== حسب حجم الاختراق ===")
T['eb']=pd.qcut(T.ext,4,labels=['صغير','متوسط','كبير','ضخم'],duplicates='drop')
print(T.groupby('eb',observed=True).agg(n=('pnl','size'),wr=('win','mean'),net=('pnl','sum')).assign(wr=lambda x:x.wr*100).to_string())
print("\n=== حسب التقلب ATR ===")
T['ab']=pd.qcut(T.atr,4,labels=['هادئ','عادي','نشط','عنيف'],duplicates='drop')
print(T.groupby('ab',observed=True).agg(n=('pnl','size'),wr=('win','mean'),net=('pnl','sum')).assign(wr=lambda x:x.wr*100).to_string())
print("\n=== حسب الاتجاه العام (240د) ===")
T['al']=np.where(T.trend*T.side.map({'BUY':1,'SELL':-1})>0,'مع الاتجاه','عكس الاتجاه')
print(T.groupby('al').agg(n=('pnl','size'),wr=('win','mean'),net=('pnl','sum')).assign(wr=lambda x:x.wr*100).to_string())
print("\n=== حسب الجانب ===")
print(T.groupby('side').agg(n=('pnl','size'),wr=('win','mean'),net=('pnl','sum')).assign(wr=lambda x:x.wr*100).to_string())
