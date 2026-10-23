import json,time,urllib.request,sys
ctx='Добрый день! Спасибо за ваше письмо. Мы рассмотрели ваше предложение по поставке земснаряда и готовы обсудить условия. '*6
for port,name in ((8801,'q4'),(8802,'q4+draft')):
  for p in [ctx+'Прошу направить', 'Hi John, thanks for the quick reply. I will send you the', 'Шановні колеги, нагадую, що завтра о 10 ранку в нас']:
    try:
      u='http://127.0.0.1:%d/completion'%port
      urllib.request.urlopen(urllib.request.Request(u,json.dumps({'prompt':p,'n_predict':1,'cache_prompt':True}).encode(),{'Content-Type':'application/json'})).read()
      t=time.time()
      r=json.load(urllib.request.urlopen(urllib.request.Request(u,json.dumps({'prompt':p,'n_predict':24,'temperature':0,'cache_prompt':True,'stop':['\n']}).encode(),{'Content-Type':'application/json'})))
      print(name, round(time.time()-t,2),'tok/s',round(r['timings'].get('predicted_per_second',0)), repr(r['content'][:50]))
    except Exception as e:
      print(name,'ERR',e)
