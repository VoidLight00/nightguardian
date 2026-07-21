#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# NightGuardian — robust rate-limit reset-time parser
# stdin(또는 --text)으로 pane 내용을 받아, 리셋 시각을 epoch(정수)로 stdout 출력.
# 어떤 시각도 못 찾으면 빈 줄 출력(호출측이 fallback 적용).
#
# 지원 형식 (Claude Code / API 가 시기에 따라 다르게 내보내는 모든 변형 대응):
#   - "resets 5pm (Asia/Seoul)"            정시·분없음·12h
#   - "Resets 6:50am (Asia/Seoul)"         분있음·12h
#   - "reset at 5:00 PM (Asia/Seoul)"      'at'·공백·대문자
#   - "resets 14:30 (Asia/Seoul)"          24h
#   - "resets at midnight / noon"          단어 시각
#   - "resets 9am (America/New_York)"      IANA 타임존
#   - "resets 3pm PST" / "11:30pm KST"     약어 타임존
#   - "try again in 30 seconds"            상대시간(초)
#   - "resets in 2h 15m" / "in 45 minutes" 상대시간(시/분)
#   - "resets tomorrow at 9am"             명시적 익일
# 의존성: 표준 라이브러리만 (re, time, sys, datetime, zoneinfo).
# ═══════════════════════════════════════════════════════════════

import re
import sys
import time
from datetime import datetime, timedelta

try:
    from zoneinfo import ZoneInfo  # py3.9+
except Exception:  # pragma: no cover
    ZoneInfo = None

# 약어 → IANA 존. 약어는 zoneinfo가 직접 모르므로 매핑한다.
ABBR = {
    "UTC": "UTC", "GMT": "Europe/London",
    "KST": "Asia/Seoul", "JST": "Asia/Tokyo", "IST": "Asia/Kolkata",
    "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles", "PT": "America/Los_Angeles",
    "EST": "America/New_York", "EDT": "America/New_York", "ET": "America/New_York",
    "CST": "America/Chicago", "CDT": "America/Chicago", "CT": "America/Chicago",
    "MST": "America/Denver", "MDT": "America/Denver", "MT": "America/Denver",
    "BST": "Europe/London", "CET": "Europe/Paris", "CEST": "Europe/Paris",
}

WORD_TIMES = {"midnight": (0, 0), "noon": (12, 0)}

# 상대시간 토큰: 값 + 단위. 긴 단위를 먼저 두어 'seconds'가 's'로 잘못 잡히지 않게 한다.
_DUR = re.compile(
    r"(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b", re.I
)
# 12시간제: 분(:MM)은 선택, am/pm 앞뒤 공백·점 허용, 대소문자 무시.
_T12 = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\b", re.I)
# 24시간제: HH:MM
_T24 = re.compile(r"\b([01]?\d|2[0-3]):([0-5]\d)\b")


def _load_zone(name):
    if not name or ZoneInfo is None:
        return None
    try:
        return ZoneInfo(name)
    except Exception:
        return None


def detect_tz(text):
    m = re.search(r"([A-Za-z]+/[A-Za-z_]+)", text)  # IANA "Area/City"
    if m:
        z = _load_zone(m.group(1))
        if z:
            return z
    m = re.search(
        r"\b(UTC|GMT|KST|JST|IST|PST|PDT|PT|EST|EDT|ET|CST|CDT|CT|MST|MDT|MT|BST|CET|CEST)\b",
        text,
    )
    if m:
        return _load_zone(ABBR.get(m.group(1).upper()))
    return None  # 못 찾으면 로컬 타임존 사용


def _to24(h, ap):
    h = int(h)
    if ap == "a":
        return 0 if h == 12 else h
    return 12 if h == 12 else (h + 12 if h != 24 else 12)


def _at_walltime(hour, minute, tz, now, tomorrow):
    if tz is not None:
        now_dt = datetime.fromtimestamp(now, tz)
    else:
        now_dt = datetime.fromtimestamp(now).astimezone()
    try:
        cand = now_dt.replace(hour=hour, minute=minute, second=0, microsecond=0)
    except ValueError:
        return None
    if tomorrow:
        cand = cand + timedelta(days=1)
    elif cand <= now_dt:
        cand = cand + timedelta(days=1)
    return int(cand.timestamp())


def parse_relative(text, now):
    low = text.lower()
    # 상대시간은 반드시 in/after/within 같은 맥락어 뒤에서만 인정(오탐 방지).
    for kw in ("try again in", "available in", "resets in", "reset in",
               "retry in", "back in", "within", " in ", "after "):
        idx = low.find(kw)
        if idx == -1:
            continue
        seg = low[idx: idx + 44]
        secs = 0
        ok = False
        for val, unit in _DUR.findall(seg):
            v = int(val)
            u = unit[0].lower()
            if u == "h":
                secs += v * 3600; ok = True
            elif u == "s":
                secs += v; ok = True
            elif u == "m":
                secs += v * 60; ok = True
        if ok and secs > 0:
            return int(now + secs)
    return None


def parse_absolute(text, now):
    # Absolute times are accepted only near reset/retry context. Pane captures
    # often contain unrelated meeting times or log timestamps.
    contexts = re.findall(
        r"(?:resets?|reset(?:s|ting)?(?:\s+at)?|try\s+again(?:\s+at)?|"
        r"available(?:\s+at)?|back(?:\s+at)?|wait(?:\s+until)?)"
        r"[^\n]{0,48}",
        text,
        re.I,
    )
    if not contexts:
        return None
    scoped = "\n".join(contexts)
    tz = detect_tz(scoped)
    tomorrow = bool(re.search(r"\btomorrow\b", scoped, re.I))
    low = scoped.lower()
    for w, (h, mn) in WORD_TIMES.items():
        if re.search(r"\b" + w + r"\b", low):
            return _at_walltime(h, mn, tz, now, tomorrow)
    m = _T12.search(scoped)
    if m:
        h = _to24(m.group(1), m.group(3).lower())
        mn = int(m.group(2) or 0)
        return _at_walltime(h, mn, tz, now, tomorrow)
    m = _T24.search(scoped)
    if m:
        return _at_walltime(int(m.group(1)), int(m.group(2)), tz, now, tomorrow)
    return None


def parse_reset(text, now=None):
    if now is None:
        now = time.time()
    return parse_relative(text, now) or parse_absolute(text, now)


# ───────────────────────────────────────────────────────────────
def _selftest():
    UTC = _load_zone("UTC")
    # 고정 now = 2026-06-17 12:00:00 KST (03:00 UTC) — 머신 타임존과 무관하게 결정론.
    now = int(datetime(2026, 6, 17, 3, 0, tzinfo=UTC).timestamp())
    cases = [
        ("You've hit your session limit · resets 5pm (Asia/Seoul)", "abs", ("Asia/Seoul", 17, 0)),
        ("You've hit your session limit. Resets 6:50am (Asia/Seoul)", "abs", ("Asia/Seoul", 6, 50)),
        ("Your limit will reset at 5:00 PM (Asia/Seoul)", "abs", ("Asia/Seoul", 17, 0)),
        ("limit will reset at 11pm (Asia/Seoul)", "abs", ("Asia/Seoul", 23, 0)),
        ("5-hour limit reached ∙ resets 8am (Asia/Seoul)", "abs", ("Asia/Seoul", 8, 0)),
        ("usage limit reached · resets 14:30 (Asia/Seoul)", "abs", ("Asia/Seoul", 14, 30)),
        ("resets 12am (Asia/Seoul)", "abs", ("Asia/Seoul", 0, 0)),
        ("resets 12pm (Asia/Seoul)", "abs", ("Asia/Seoul", 12, 0)),
        ("resets at midnight (Asia/Seoul)", "abs", ("Asia/Seoul", 0, 0)),
        ("resets at noon (Asia/Seoul)", "abs", ("Asia/Seoul", 12, 0)),
        ("resets 9am (America/New_York)", "abs", ("America/New_York", 9, 0)),
        ("resets 3pm PST", "abs", ("America/Los_Angeles", 15, 0)),
        ("resets 11:30pm KST", "abs", ("Asia/Seoul", 23, 30)),
        ("You've hit your usage limit · resets 7pm (UTC)", "abs", ("UTC", 19, 0)),
        ("resets tomorrow at 9am (Asia/Seoul)", "abs", ("Asia/Seoul", 9, 0)),
        ("Please try again in 30 seconds", "rel", 30),
        ("Please try again in 45 minutes", "rel", 45 * 60),
        ("resets in 2h 15m", "rel", 2 * 3600 + 15 * 60),
        ("available in 1 hour", "rel", 3600),
        ("resets in 90 minutes", "rel", 90 * 60),
        ("You've hit your session limit. Please wait.", "none", None),
        ("You've hit your usage limit. reset time unavailable\nstandup moved to 2pm", "none", None),
    ]
    fails = 0
    for text, kind, exp in cases:
        r = parse_reset(text, now)
        ok = False
        detail = ""
        if kind == "none":
            ok = r is None
            detail = "None" if ok else "epoch=%s" % r
        elif kind == "rel":
            ok = r is not None and abs(r - now - exp) <= 90
            detail = "" if r is None else "+%ds" % (r - now)
        elif kind == "abs":
            tzname, h, mn = exp
            z = _load_zone(tzname)
            if r is not None and r > now and z is not None:
                dt = datetime.fromtimestamp(r, z)
                ok = dt.hour == h and dt.minute == mn
                detail = dt.strftime("%Y-%m-%d %H:%M %Z")
            else:
                detail = "epoch=%s" % r
        flag = "PASS" if ok else "FAIL"
        if not ok:
            fails += 1
        print("%s  %-52s -> %s" % (flag, text[:52], detail))
    print("─" * 60)
    print("RESULT: %d/%d passed" % (len(cases) - fails, len(cases)))
    return 1 if fails else 0


def main(argv):
    if "--selftest" in argv:
        return _selftest()
    now = None
    if "--now" in argv:
        now = float(argv[argv.index("--now") + 1])
    text = ""
    if "--text" in argv:
        text = argv[argv.index("--text") + 1]
    else:
        try:
            text = sys.stdin.read()
        except Exception:
            text = ""
    r = parse_reset(text, now)
    print(r if r else "")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
