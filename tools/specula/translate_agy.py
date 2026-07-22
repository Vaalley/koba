#!/usr/bin/env python3
"""
translate_agy.py

Helper script to translate Vulkan tutorial lessons using Specula + AGY (Antigravity completion).

Usage:
    python tools/specula/translate_agy.py <url-or-path> [--out <output.md>]

Requirements:
    - Must be run within the OMP (Oh My Pi) harness session environment (or Python kernel with completion built-in).
    - Requires Deno to perform Specula's dry-run RAG retrieval.
"""

import os
import sys
import subprocess
from pathlib import Path

# Try importing built-in `completion` if available in IPython/OMP eval kernel
try:
    from omp import completion # type: ignore
except ImportError:
    completion = None

def get_specula_prompts(source_url_or_path: str):
    specula_dir = Path(__file__).parent.resolve()
    cmd = [
        "deno", "task", "translate",
        source_url_or_path,
        "--dry-run"
    ]
    res = subprocess.run(cmd, cwd=specula_dir, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Specula dry-run failed:\n{res.stderr}")
    
    stdout = res.stdout
    sys_marker = "=== System prompt ==="
    user_marker = "=== User prompt ==="
    
    if sys_marker not in stdout or user_marker not in stdout:
        raise RuntimeError(f"Unexpected specula dry-run output:\n{stdout}")
    
    sys_idx = stdout.find(sys_marker)
    user_idx = stdout.find(user_marker)
    
    system_prompt = stdout[sys_idx + len(sys_marker):user_idx].strip()
    
    # User prompt goes until token estimate line or end
    user_part = stdout[user_idx + len(user_marker):].strip()
    
    return system_prompt, user_part

def slugify(url_or_path: str) -> str:
    name = url_or_path.split("/")[-1].split("\\")[-1]
    if name.endswith(".html") or name.endswith(".md"):
        name = name.rsplit(".", 1)[0]
    clean = "".join(c if c.isalnum() or c in "-_" else "-" for c in name.lower())
    return clean.strip("-") or "lesson"

def main():
    if len(sys.argv) < 2:
        print("Usage: python translate_agy.py <url-or-path> [--out <output.md>]")
        sys.exit(1)
        
    source = sys.argv[1]
    out_path = None
    if "--out" in sys.argv:
        idx = sys.argv.index("--out")
        if idx + 1 < len(sys.argv):
            out_path = Path(sys.argv[idx + 1])
    if out_path is None:
        specula_dir = Path(__file__).parent.resolve()
        url_end = source.split("/")[-1].split("\\")[-1]
        slug = "".join(c if c.isalnum() else "-" for c in url_end.lower()).strip("-")
        out_path = specula_dir / "docs" / f"{slug}.md"
    print(f"[koba-specula] [1/3] Extracting RAG context & prompts for: {source}")
    system_prompt, user_prompt = get_specula_prompts(source)
    print(f"  • System prompt: {len(system_prompt)} chars (~{len(system_prompt)//4} tokens)")
    print(f"  • User prompt: {len(user_prompt)} chars (~{len(user_prompt)//4} tokens)")

    # If global `completion` function is present in globals (e.g. OMP IPython environment)
    comp_func = globals().get("completion") or completion
    print("[koba-specula] [2/3] Submitting prompts to AGY (Antigravity completion model)...")

    if comp_func is None:
        # Check if PI_TOOL_BRIDGE_URL is set for HTTP request
        bridge_url = os.environ.get("PI_TOOL_BRIDGE_URL")
        bridge_token = os.environ.get("PI_TOOL_BRIDGE_TOKEN")
        bridge_session = os.environ.get("PI_TOOL_BRIDGE_SESSION")
        
        if bridge_url and bridge_token:
            import urllib.request
            import json
            print(f"  • Connecting via OMP harness bridge endpoint: {bridge_url}/v1/tool")
            req_data = {
                "session": bridge_session if bridge_session else "default",
                "run": os.environ.get("OMP_RUN_ID", "default"),
                "name": "__completion__",
                "args": {
                    "prompt": user_prompt,
                    "system": system_prompt,
                    "model": "default"
                }
            }
            req = urllib.request.Request(
                f"{bridge_url}/v1/tool",
                data=json.dumps(req_data).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {bridge_token}"
                },
                method="POST"
            )
            with urllib.request.urlopen(req) as resp:
                res_json = json.loads(resp.read().decode("utf-8"))
                if not res_json.get("ok"):
                    raise RuntimeError(f"Bridge error: {res_json.get('error')}")
                translated_md = res_json["value"]["text"]
        else:
            raise RuntimeError(
                "Neither `completion()` built-in nor `PI_TOOL_BRIDGE_URL` environment variables are available.\n"
                "To use AGY, run inside an OMP session/eval or pass OpenRouter key for CLI."
            )
    else:
        print("  • Executing built-in session completion...")
        translated_md = comp_func(user_prompt, model="default", system=system_prompt)

    print("[koba-specula] [3/3] Writing translated Markdown output...")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(translated_md, encoding="utf-8")
    print(f"[koba-specula] Successfully saved AGY translation to {out_path.resolve()} ({len(translated_md)} bytes)")
if __name__ == "__main__":
    main()
