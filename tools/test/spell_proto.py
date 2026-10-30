import struct, time, collections
def load(l, minf=2):
    b=open(f'data/dict/{l}.exd','rb').read()
    n,nb,bs,dl=struct.unpack('<IIII',b[4:20]); data=b[20+nb*4+(nb+1)*4:]
    pos=0; prev=b''; out=[]
    def vi():
        nonlocal pos
        r=sh=0
        while True:
            x=data[pos]; pos+=1; r|=(x&0x7f)<<sh
            if not x&0x80: return r
            sh+=7
    for i in range(n):
        if i%bs==0: L=vi(); w=data[pos:pos+L]; pos+=L
        else:
            s=data[pos]; pos+=1; L=vi(); w=prev[:s]+data[pos:pos+L]; pos+=L
        f=vi(); prev=w
        if f>=minf: out.append((w.decode(),f))
    return out
def osa(a,b,k):
    n,m=len(a),len(b)
    if abs(n-m)>k: return k+1
    prev2=None; prev=list(range(m+1))
    for i in range(1,n+1):
        cur=[i]+[0]*m; best=i
        for j in range(1,m+1):
            c=0 if a[i-1]==b[j-1] else 1
            v=min(prev[j]+1,cur[j-1]+1,prev[j-1]+c)
            if i>1 and j>1 and a[i-1]==b[j-2] and a[i-2]==b[j-1]: v=min(v,prev2[j-2]+1)
            cur[j]=v; best=min(best,v)
        if best>k: return k+1
        prev2,prev=prev,cur
    return prev[m]
def maxd(w): return 1 if len(w)<=4 else 2 if len(w)<=8 else 3 if len(w)<=11 else 4
idx={}; freq={}; UNV={}
for l in ('ru','uk','en'):
    t=time.time(); words=load(l)
    b=collections.defaultdict(list)
    unv=set(open(f'data/dict/{l}.unverified',encoding='utf-8').read().split('\n'))
    freq[l]=dict(words); UNV[l]=unv
    for w,f in words:
        if w not in unv: b[w[0]].append((w,f))
    idx[l]=b; print(l,len(words),'loaded',round(time.time()-t,1),'s')
def fix(w,l):
    wf=freq[l].get(w,0)
    if wf and (w not in UNV[l] or wf>=2000): return ('known',wf)
    k=maxd(w); best=None
    for first in {w[0], w[1] if len(w)>1 else w[0]}:
        for c,f in idx[l][first]:
            if abs(len(c)-len(w))>k: continue
            d=osa(w,c,k)
            if d<=k and (best is None or (d,-f)<(best[0],-best[2])): best=(d,c,f)
    if best and wf and best[2] < wf*300: return ('keep',wf,best)
    return best
for l,w in [('ru','хорактестиски'),('ru','характеристики'),('ru','мостик'),('ru','кот'),('ru','гугл'),('en','gonna'),('uk','шось'),('ru','првиет'),('ru','спасиюо'),('ru','сегодян'),('ru','пожалуйчта'),('ru','кнечно'),('uk','дякуюю'),('uk','будь-ласка'),('uk','зараз'),('uk','звичано'),('en','teh'),('en','recieve'),('en','tommorow'),('en','definately'),('en','wierd')]:
    t=time.time(); r=fix(w,l); print(l,w,'->',r, round((time.time()-t)*1000),'ms')
