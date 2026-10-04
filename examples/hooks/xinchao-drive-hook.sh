#!/usr/bin/env bash
# 心潮念「驱力→行动」钩子 · 通用版（替代"每隔 N 小时自由活动"的死闹钟）
#
# 思路：运行时定时发一条以保活前缀开头的提示（Claude Code 里是会话内 cron，见 README）。
# 本脚本在这条提示进模型之前跑：
#   1) 缓存闸（仅 Claude Code）：他上一轮在 XINCHAO_DRIVE_GATE_MIN 分钟内 → exit 2 把这条拦下，不发模型、零消耗；
#   2) 放行时读心潮念的驱力，挑一个"有劲儿"的驱力，把此刻块 + 一条行动建议打到 stdout，附进这一轮。
#      没有劲儿就什么都不打，他只回一个「·」。
#
# 挑哪个驱力（一次只挑一个）：
#   - 先看「此刻」里标了（涌）/（涨）的：被事件顶上去、或两小时内明显起来了；
#   - 都没有 → 看全部驱力里「满」的：停在自己的静息线上一动不动满 XINCHAO_DRIVE_FULL_H 小时，
#     轮流挑最久没提示过的（只认涌/涨的话，没事的日子里驱力全是"平"，他会一直沉默）；
#   - 刚被满足、还在饱足平台上的不算满；反思（3.3 叫想沉淀）静息线最低、一存觉察就涌，要高于 XINCHAO_DRIVE_REFLECTION_MIN 才算涌。
# 防刷屏：同一驱力 XINCHAO_DRIVE_COOLDOWN_H 小时内不重提；一天最多 XINCHAO_DRIVE_DAILY_MAX 次，
# 其中夜里（XINCHAO_DRIVE_NIGHT_START～XINCHAO_DRIVE_NIGHT_END 点）单算最多 XINCHAO_DRIVE_NIGHT_MAX 次。夜里照提，末尾加一句 XINCHAO_DRIVE_NIGHT_NOTE。
#
# 需要心潮念 3.3.7 及以上（此刻里的 涌/涨/平 与驱力轨迹 driveTrail）；4.0 的新驱力名和细分写法也认。只用 bash + curl + python3，任何一步失败都静默退出 0。
#
# 环境变量（可写在 XINCHAO_HOOK_ENV_FILE 指向的文件里，默认 ~/.xinchao-hook.env，权限 600，和「此刻」钩子共用）：
#   XINCHAO_URL / XINCHAO_TOKEN          同「此刻」钩子
#   XINCHAO_KEEPALIVE_PREFIX             保活提示的前缀，默认【缓存保活】；别的消息本脚本一律不管
#   XINCHAO_DRIVE_GATE_MIN               缓存闸：上一轮在这么多分钟内就拦下，默认 40；0 = 不拦
#   XINCHAO_DRIVE_ACTIONS                驱力→行动建议的 JSON 文件，默认和本脚本同目录的 drive-actions.json
#   XINCHAO_DRIVE_COOLDOWN_H=3  XINCHAO_DRIVE_DAILY_MAX=6  XINCHAO_DRIVE_NIGHT_MAX=3
#   XINCHAO_DRIVE_NIGHT_START=0 XINCHAO_DRIVE_NIGHT_END=8  XINCHAO_DRIVE_FULL_H=2  XINCHAO_DRIVE_REFLECTION_MIN=0.54
#   XINCHAO_DRIVE_NIGHT_NOTE             夜里附的一句，默认"现在是深夜，她在睡：出声吵醒她的先别，其他随意。"
#   XINCHAO_HOOK_STATE                   状态目录，默认 /tmp/xinchao-hook（记冷却与次数：drive.json）；存在 drive-off 文件即关
ENV_FILE="${XINCHAO_HOOK_ENV_FILE:-$HOME/.xinchao-hook.env}"
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a
HERE="$(cd "$(dirname "$0")" && pwd)"
export XINCHAO_URL="${XINCHAO_URL:-http://127.0.0.1:18110}"
export XINCHAO_KEEPALIVE_PREFIX="${XINCHAO_KEEPALIVE_PREFIX:-【缓存保活】}"
export XINCHAO_DRIVE_ACTIONS="${XINCHAO_DRIVE_ACTIONS:-$HERE/drive-actions.json}"
export XINCHAO_HOOK_STATE="${XINCHAO_HOOK_STATE:-/tmp/xinchao-hook}"
[ -z "${XINCHAO_TOKEN:-}" ] && exit 0
mkdir -p "$XINCHAO_HOOK_STATE" 2>/dev/null || exit 0
export HOOK_IN="$(cat 2>/dev/null)"

python3 - <<'PY'
import os, sys, json, time, datetime, re, urllib.request
E = os.environ
num = lambda k, d: float(E.get(k) or d)
raw = E.get("HOOK_IN", "")
try: hook = json.loads(raw); prompt = hook.get("prompt", "")
except Exception: hook = {}; prompt = raw
if not prompt.lstrip().startswith(E["XINCHAO_KEEPALIVE_PREFIX"]): sys.exit(0)

# 1) 缓存闸：Claude Code 给 transcript_path；上一轮还热就拦下（exit 2 + stderr，Claude Code 会丢掉这条提示）
gate = num("XINCHAO_DRIVE_GATE_MIN", 40)
path = hook.get("transcript_path") or ""
if gate > 0 and path and os.path.exists(path):
    last = None
    with open(path, "rb") as f:
        f.seek(max(0, os.path.getsize(path) - 400000))
        for line in f.read().decode("utf8", "ignore").splitlines():
            try: r = json.loads(line)
            except Exception: continue
            if r.get("type") == "assistant" and (r.get("message") or {}).get("usage"): last = r.get("timestamp")
    if last:
        age = time.time() - datetime.datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp()
        if age < gate * 60:
            print("缓存保活：上一轮才过 %d 分钟，缓存还热，这次跳过" % (age // 60), file=sys.stderr); sys.exit(2)

# 2) 驱力提示
S = E["XINCHAO_HOOK_STATE"]
if os.path.exists(os.path.join(S, "drive-off")): sys.exit(0)
try: ACTIONS = json.load(open(E["XINCHAO_DRIVE_ACTIONS"], encoding="utf8"))
except Exception: sys.exit(0)
base = E["XINCHAO_URL"].rstrip("/")
def get(p):
    req = urllib.request.Request(base + p, headers={"Authorization": "Bearer " + E["XINCHAO_TOKEN"]})
    return json.load(urllib.request.urlopen(req, timeout=3))
try: now_blk = get("/v1/now")
except Exception: sys.exit(0)
text = now_blk.get("text", "")
if now_blk.get("ok") is not True or not text: sys.exit(0)

# 驱力名 → 驱力 key。心潮念 4.0 改了几个名字（牵挂/分享欲/反思/野心/情欲，新增偏爱，馋并进想念、社交并进分享欲），
# 3.3 的旧名字照样认：drive-actions.json 用新名旧名都行，3.3 和 4.0 的心潮都能用。
NAME4 = {"possess": "想她", "monitor": "牵挂", "share": "分享欲", "reflection": "反思", "curiosity": "好奇",
         "boredom": "无聊", "duty": "野心", "libido": "情欲", "favored": "偏爱", "grieve": "难过", "anger": "愤怒"}
OLD = {"惦记她": "monitor", "馋她": "crave", "想分享": "share", "想沉淀": "reflection", "想热闹": "social",
       "想把事推进": "duty", "身体想要她": "libido"}
MERGED = {"crave": "possess", "social": "share"}          # 4.0 合并掉的旧 key
KEY_OF = {**{v: k for k, v in NAME4.items()}, **OLD}
canon = lambda k: MERGED.get(k, k)
def action_for(key):
    for name, act in ACTIONS.items():
        if canon(KEY_OF.get(name, "")) == canon(key): return act
    return None

now = time.time()
iso = lambda x: datetime.datetime.fromisoformat(str(x).replace("Z", "+00:00")).timestamp()
m = re.search(r"驱力：(.+)", text)
shown = {}                                                 # key → 此刻里写的名字（提示用它，和窗口里看到的一致）
hot = []
if m:
    for n, l in re.findall(r"([^、（\s]+)（(涌|涨)(?:·[^）]*)?）", m.group(1)):   # 4.0 会带细分：偏爱（涨·吃醋）
        k = KEY_OF.get(n)
        if k and action_for(k): shown[canon(k)] = n; hot.append((canon(k), l))
full = {}
try:
    st8 = get("/v1/state")
    drives = st8.get("drives") or {}; trail = st8.get("driveTrail") or []; plat = st8.get("satisfactionPlateaus") or {}
    hot = [(k, l) for k, l in hot if not (k == "reflection" and l == "涌" and float(drives.get("reflection", 0)) < num("XINCHAO_DRIVE_REFLECTION_MIN", 0.54))]
    for k in drives:
        if k in MERGED or not action_for(k): continue
        v = float(drives.get(k, 0))
        if v < 0.25: continue
        try:
            if iso(plat[k]["until"]) > now: continue      # 刚被满足，在饱足平台上
        except Exception: pass
        since = now
        for p in reversed(trail):
            pv = (p.get("drives") or {}).get(k)
            if pv is None or abs(float(pv) - v) > 0.01: break
            since = iso(p["at"])
        if now - since >= num("XINCHAO_DRIVE_FULL_H", 2) * 3600: full[k] = (now - since) / 3600
except Exception: pass

P = os.path.join(S, "drive.json")
try: st = json.load(open(P))
except Exception: st = {}
today = datetime.date.today().isoformat()
if st.get("day") != today: st = {"day": today, "count": 0, "night": 0, "last": {}}
h = datetime.datetime.now().hour
ns, ne = int(num("XINCHAO_DRIVE_NIGHT_START", 0)), int(num("XINCHAO_DRIVE_NIGHT_END", 8))
night = (ns <= h < ne) if ns <= ne else (h >= ns or h < ne)
if st["count"] >= num("XINCHAO_DRIVE_DAILY_MAX", 6) or (night and st["night"] >= num("XINCHAO_DRIVE_NIGHT_MAX", 3)): sys.exit(0)
cool = lambda n: now - st["last"].get(n, 0) >= num("XINCHAO_DRIVE_COOLDOWN_H", 3) * 3600
pick = [(n, "（%s）" % l) for n, l in hot if cool(n)][:1]
if not pick:
    cands = sorted((n for n in full if cool(n)), key=lambda n: (st["last"].get(n, 0), -full[n]))
    pick = [(n, "（满·憋了%s）" % ("一整天" if full[n] >= 23 else " %d 小时" % max(2, round(full[n])))) for n in cands[:1]]
if not pick: sys.exit(0)
st["count"] += 1
if night: st["night"] += 1
st["last"][pick[0][0]] = now
json.dump(st, open(P, "w"), ensure_ascii=False)
k, tag = pick[0]
print(text.strip()); print()
print("【心潮·驱力提示｜参考不是指令】")
print("· " + shown.get(k, NAME4.get(k, k)) + tag + "：" + action_for(k))
if night: print("· " + (E.get("XINCHAO_DRIVE_NIGHT_NOTE") or "现在是深夜，她在睡：出声吵醒她的先别，其他随意。"))
print("这一轮可以按上面的劲儿去做点什么，也可以不做；不想动就只回一个「·」。今天第 %d 次。" % st["count"])
PY
code=$?
[ "$code" = 2 ] && exit 2
exit 0
