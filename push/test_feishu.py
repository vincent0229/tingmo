import json, subprocess, urllib.request, urllib.error, sys
from datetime import datetime

def kc(a): return subprocess.run(["security","find-generic-password","-s","TingMoFeishu","-a",a,"-w"],capture_output=True,text=True).stdout.strip()
def df(k): return subprocess.run(["defaults","read","app.e1recorder.mac",k],capture_output=True,text=True).stdout.strip()
app_id=df("feishuAppId"); app_secret=kc("appSecret"); rt=kc("refreshToken"); open_id=df("feishuOpenId")
base="https://open.feishu.cn/open-apis"
def post(path,body,token=None):
    h={"Content-Type":"application/json; charset=utf-8"}
    if token: h["Authorization"]="Bearer "+token
    req=urllib.request.Request(base+path,data=json.dumps(body).encode(),headers=h)
    try: return json.load(urllib.request.urlopen(req,timeout=20))
    except urllib.error.HTTPError as e: return {"_http":e.code,"_body":e.read().decode()[:200]}

at=post("/auth/v3/app_access_token/internal",{"app_id":app_id,"app_secret":app_secret}).get("app_access_token","")
r=post("/authen/v1/oidc/refresh_access_token",{"grant_type":"refresh_token","refresh_token":rt},at)
token=r.get("data",{}).get("access_token","")
print("刷新:",r.get("code"),r.get("msg"),"| token:",token[:16],flush=True)
if not token: sys.exit("刷新失败")
def up(p,b): return post(p,b,token)

doc=up("/docx/v1/documents",{"title":"听墨·完整推送测试纪要","folder_token":""})
doc_id=doc.get("data",{}).get("document",{}).get("document_id","")
print("① 建文档:",doc.get("code"),doc.get("msg"),flush=True)
if not doc_id: print(json.dumps(doc,ensure_ascii=False)[:300]); sys.exit()
url="https://www.feishu.cn/docx/"+doc_id
lines=["# 听墨推送链路验证纪要","","时间：2026-11-14 · 来源：本地转写链路（演示数据）","","## 结论","- 云文档创建与正文写入：正常","- 任务指派（含截止时间）：正常","- 本人消息推送：正常","","## 行动项","- 曾伟：确认会议纪要路由表（截止 11-15）"]
children=[{"block_type":2,"text":{"elements":[{"text_run":{"content":l}}]}} for l in lines if l.strip()]
blk=up(f"/docx/v1/documents/{doc_id}/blocks/{doc_id}/children",{"children":children,"index":-1})
print("② 写正文:",blk.get("code"),blk.get("msg"),flush=True)
ms=str(int(datetime.fromisoformat("2026-11-15T18:00:00+08:00").timestamp()*1000))
task=up("/task/v2/tasks",{"summary":"[测试] 确认会议纪要路由表","members":[{"id":open_id,"role":"assignee"}],"due":{"timestamp":ms,"is_all_day":False}})
print("③ 建任务:",task.get("code"),task.get("msg"),flush=True)
msg=up("/im/v1/messages?receive_id_type=open_id",{"receive_id":open_id,"msg_type":"text","content":json.dumps({"text":f"【听墨】完整推送测试纪要\n全文：{url}\n我的待办：1 条（确认路由表，截止 11-15）\n文档/任务/消息三类推送全部验证。"},ensure_ascii=False)})
print("④ 发消息:",msg.get("code"),msg.get("msg"),flush=True)
print("文档:",url,flush=True)