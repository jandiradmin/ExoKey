import json,urllib.request
for p in ['Спасибо за','Привет! Как у тебя','Я сегодня поеду в город и куплю','Hi John, thanks for the quick reply. I will send you the']:
    r=json.load(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8737/completion',json.dumps({'prompt':p,'n_predict':16,'temperature':0,'cache_prompt':True,'stop':['\n'],'n_probs':1,'post_sampling_probs':False}).encode(),{'Content-Type':'application/json'})))
    cp=r.get('completion_probabilities',[])
    print(p,'|', ' '.join('%s(%.2f)'%(t.get('token'),__import__('math').exp(t.get('logprob',-99))) for t in cp))
print(list(cp[0].keys()) if cp else r.keys())
