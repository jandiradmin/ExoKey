import json, urllib.request, time
U = 'http://127.0.0.1:8737/completion'
def comp(prompt, n=24):
    r = json.load(urllib.request.urlopen(urllib.request.Request(U, json.dumps({'prompt': prompt, 'n_predict': n, 'temperature': 0, 'cache_prompt': True, 'stop': ['\n', '<|im_end|>']}).encode(), {'Content-Type': 'application/json'})))
    return r['content']
SYS = ("You are an autocomplete engine inside the user's keyboard. The user is typing a message. "
       "Continue the user's draft with the most likely next words, in the same language, tone and style. "
       "Use the conversation for context. Write only the continuation of the draft, never repeat it, never answer for the other person.")
cases = [
  ("Telegram", "Марина: Ты сегодня во сколько будешь дома?\nМарина: Купи хлеба и молока по дороге", "Буду около 7, хлеб и"),
  ("Telegram", "Андрій: Привіт! Чи можете надіслати комерційну пропозицію на земснаряд 200 м3/год?", "Добрий день, Андрію! Так, звичайно. Надішлю"),
  ("Mail", "From: John Smith\nSubject: Invoice #2241\nHi Yan, could you confirm the payment date for the last invoice? Thanks, John", "Hi John, thanks for reaching out. The payment"),
  ("Claude", "Claude: Готово, релиз 0.1.0 опубликован на GitHub. Что дальше?", "Отлично, теперь давай сделаем"),
  ("Slack", "Alina: the Genesis G70 is back from the shop, renter picks up at 3", "Great, can you"),
]
for app, ctx, draft in cases:
    raw = ctx + "\n\n" + draft
    chat = (f"<|im_start|>system\n{SYS}<|im_end|>\n<|im_start|>user\nApp: {app}\nConversation above the input field:\n\"\"\"\n{ctx}\n\"\"\"\n<|im_end|>\n<|im_start|>assistant\n{draft}")
    t = time.time(); a = comp(raw); ta = time.time() - t
    t = time.time(); b = comp(chat); tb = time.time() - t
    print(f"== {draft}\n  RAW  ({ta:.2f}s): {a!r}\n  CHAT ({tb:.2f}s): {b!r}")
