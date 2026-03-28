#!/usr/bin/env python3
"""Add zh-Hans translations to all .xcstrings files via Anthropic API with retry."""
import json, os, time, urllib.request, urllib.error, re
from pathlib import Path

PROXY = "http://127.0.0.1:15721"
TOKEN = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
MODEL = "claude-sonnet-4-6"
BATCH = 15

def call(prompt, retries=3):
    data = json.dumps({"model": MODEL, "max_tokens": 4096,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(f"{PROXY}/v1/messages", data=data,
                headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json",
                         "anthropic-version": "2023-06-01"}, method="POST")
            raw = urllib.request.urlopen(req, timeout=180).read().decode()
            for item in json.loads(raw).get("content", []):
                if item.get("type") == "text":
                    return item["text"]
            return ""
        except Exception as e:
            print(f"    attempt {attempt+1} failed: {e}")
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
    return ""

def src(entry):
    for lang in ("en", "de"):
        loc = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if loc.get("value"):
            return loc["value"]
    return None

def translate(items):
    if not items:
        return {}
    block = "\n".join(f"{i+1}. {k}" for i, (k, v) in enumerate(items))
    vals = "\n".join(f"{i+1}. {v}" for i, (k, v) in enumerate(items))
    prompt = f"""You are a professional translator for a macOS app (TypeWhisper - speech to text).
Translate these English strings to Simplified Chinese.

Rules:
- Keep ALL format specifiers: %@, %lld, %1$@, %2$@, %1$lld, %d, %f, %1$@/%2$@
- Keep placeholders: {{{{DATE}}}}, {{{{TIME}}}}, {{{{CLIPBOARD}}}}
- Keep brand names: TypeWhisper, API, JSON, URL, HTTP, WhisperKit, etc.
- Use professional software UI Chinese

Keys:
{block}

English values:
{vals}

Reply ONLY with a JSON object mapping each KEY (exact original) to Chinese translation:
{{"key1": "翻译1", "key2": "翻译2"}}"""
    text = call(prompt)
    if not text:
        return {}
    try:
        m = re.search(r'\{[\s\S]*\}', text)
        return json.loads(m.group()) if m else {}
    except json.JSONDecodeError:
        print(f"    JSON parse failed: {text[:200]}")
        return {}

def process(fp):
    data = json.load(open(fp))
    strings = data.get("strings", {})
    pending = [(k, src(v)) for k, v in strings.items()
               if "zh-Hans" not in v.get("localizations", {}) and src(v)]
    if not pending:
        print(f"  SKIP {fp.name} ({len(strings)} strings, all translated)")
        return 0
    print(f"  {fp.name}: translating {len(pending)}/{len(strings)}...")
    done = 0
    for i in range(0, len(pending), BATCH):
        batch = pending[i:i+BATCH]
        results = translate(batch)
        for k, v in results.items():
            if k in strings:
                strings[k].setdefault("localizations", {})["zh-Hans"] = {
                    "stringUnit": {"state": "translated", "value": v}}
                done += 1
        time.sleep(1)
    json.dump(data, open(fp, "w"), ensure_ascii=False, indent=2)
    print(f"  -> {done}/{len(pending)} written")
    return done

root = Path("/Users/qiming/workspace/typewhisper-mac")
files = sorted(root.glob("**/*.xcstrings"))
print(f"Found {len(files)} .xcstrings files\n")
total = sum(process(f) for f in files)
print(f"\nDone! {total} translations added.")
