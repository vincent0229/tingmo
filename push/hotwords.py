#!/usr/bin/env python3
"""日历上下文注入（FR-14）：拉今日钉钉/飞书日程 → 提取标题/参会人 → 热词表。
适配层转写时自动合并 adapter/hotwords.txt，人名/项目名识别更准。
用法：python3 push/hotwords.py   （建议每天会前跑，或挂定时任务）
"""
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "adapter", "hotwords.txt")
STOP = {"会议", "周会", "例会", "日程", "提醒", "上午", "下午", "今天", "明天", "本周"}


def collect(obj, bag):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and any(t in k.lower() for t in ("title", "summary", "name", "subject")):
                bag.add(v.strip())
            else:
                collect(v, bag)
    elif isinstance(obj, list):
        for x in obj:
            collect(x, bag)


def grab(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        bag = set()
        collect(json.loads(p.stdout), bag)
        return bag
    except Exception as e:
        print(f"  {' '.join(argv[:3])} 失败: {e}")
        return set()


def main():
    # 钉钉：DWS 宿主网关禁止脚本内调用，由助手直执
    # dws calendar +agenda --format json --output /tmp/dws-agenda.json 后读取
    words = set()
    if os.path.exists("/tmp/dws-agenda.json"):
        try:
            collect(json.load(open("/tmp/dws-agenda.json", encoding="utf-8")), words)
        except Exception as e:
            print(f"  dws-agenda.json 解析失败: {e}")
    else:
        print("  /tmp/dws-agenda.json 不存在（请先直执 dws calendar +agenda --output）")
    words |= grab(["lark-cli", "calendar", "+agenda"])
    # 从标题里再切出可能的人名/项目词（2-6字中文片段）
    extra = set()
    for w in words:
        extra |= set(re.findall(r"[\u4e00-\u9fa5]{2,6}", w))
    words = {w for w in (words | extra) if 2 <= len(w) <= 20 and w not in STOP}
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(words)))
    print(f"热词 {len(words)} 个 → {OUT}")
    print("、".join(sorted(words)[:30]))


if __name__ == "__main__":
    main()