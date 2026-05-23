import os
import json
import base64
import httpx
from ollama import chat
from openai import OpenAI

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="SmartCity AI Service")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OLLAMA_MODEL    = os.getenv("OLLAMA_MODEL", "qwen2.5:7b")
NVIDIA_API_KEY  = os.getenv("NVIDIA_API_KEY", "")
NVIDIA_MODEL    = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
NVIDIA_BASE_URL = "https://integrate.api.nvidia.com/v1"

# ---------------------------------------------------------------------------
# NVIDIA client (Nemotron — image detection)
# ---------------------------------------------------------------------------
nvidia_client = None
if not NVIDIA_API_KEY:
    print("[WARNING] NVIDIA_API_KEY is not set — /detect will not work!")
else:
    nvidia_client = OpenAI(base_url=NVIDIA_BASE_URL, api_key=NVIDIA_API_KEY)
    print("[INFO] Nemotron ready")

# ---------------------------------------------------------------------------
# Startup: verify Ollama is reachable
# ---------------------------------------------------------------------------
import httpx as _httpx
_OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
try:
    _r = _httpx.get(_OLLAMA_HOST, timeout=3)
    print(f"[INFO] Ollama is running at {_OLLAMA_HOST} (HTTP {_r.status_code}) — model: {OLLAMA_MODEL}")
except Exception as _e:
    print(f"[WARNING] Ollama does NOT appear to be running at {_OLLAMA_HOST}: {_e}")
    print(f"[WARNING] Run 'ollama serve' then 'ollama pull {OLLAMA_MODEL}' before using /analyze")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
VALID_CATEGORIES = ["pothole", "manhole", "lamppost", "speedBump", "treeInRoad", "brokenRoad"]

CATEGORY_LABELS = {
    "pothole":       "a pothole or hole in the road surface",
    "brokenRoad":    "broken, cracked, or damaged road surface",
    "treeInRoad":    "a fallen tree or large branch blocking the road",
    "unpavedStreet": "an unpaved, dirt, or gravel street that should be paved",
    "manhole":       "an open, broken, or raised manhole cover",
    "lamppost":      "a damaged, fallen, or non-working street lamp or lamppost",
    "speedBump":     "a damaged, missing, or unmarked speed bump",
    "other":         "an unspecified road or street infrastructure issue",
}

# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------
class AnalyzeRequest(BaseModel):
    category:             str
    sub_problem:          str | None = None   # user's dropdown selection (e.g. "Large pothole")
    description:          str | None = None   # user's free-text description
    image_url:            str | None = None   # legacy single-image field
    lat:                  float
    lon:                  float
    still_votes:          int = 0
    is_predefined:        bool = False
    # Fields populated after /detect runs (Nemotron output)
    image_description:    str | None = None   # Nemotron's visual reasoning text
    image_count:          int = 1
    nemotron_detected:    bool = False
    nemotron_category:    str = "other"
    nemotron_confidence:  float = 0.0


class AnalyzeResponse(BaseModel):
    valid:      bool
    confidence: float
    reason:     str
    priority:   str


class DetectRequest(BaseModel):
    image_url:  str | None = None
    image_urls: list[str]  = []


class DetectResponse(BaseModel):
    detected:          bool
    category:          str
    confidence:        float
    all_detections:    list
    image_description: str = ""


# ---------------------------------------------------------------------------
# PASS 1 — Qwen analyzes TEXT evidence only
#
# The LLM reasons purely about what the citizen reported (category +
# sub_problem or description + votes). No image context here intentionally —
# we want an unbiased text-only assessment first.
# Output: a plain-text reasoning paragraph (NOT JSON).
# ---------------------------------------------------------------------------
def _build_text_pass_prompt(
    category: str,
    sub_problem: str | None,
    description: str | None,
    still_votes: int,
    is_predefined: bool,
) -> str:
    cat_label = CATEGORY_LABELS.get(category, category)
    vote_line = f"\nCommunity votes confirming it is still present: {still_votes}." if still_votes > 0 else ""

    if is_predefined and sub_problem:
        evidence = (
            f"The citizen used a dropdown menu to report:\n"
            f"  Category   : {category} — {cat_label}\n"
            f"  Issue type : {sub_problem}{vote_line}"
        )
    elif description:
        evidence = (
            f"The citizen typed a free-text description:\n"
            f"  Category    : {category} — {cat_label}\n"
            f"  Description : \"{description}\"{vote_line}"
        )
    else:
        evidence = f"The citizen reported:\n  Category : {category} — {cat_label}{vote_line}"

    return f"""You are analyzing the TEXT EVIDENCE of a citizen road report.
Do NOT make a final verdict yet — just reason about the text alone.

{evidence}

In 2–3 sentences answer:
- Is this a plausible road issue based on the text?
- Does the reported issue match the chosen category?
- What severity would you expect from this problem?

Write ONLY the reasoning paragraph. No JSON, no labels, no bullet points."""


# ---------------------------------------------------------------------------
# PASS 2 — Qwen makes the FINAL decision using BOTH reasonings
#
# The LLM now sees the text reasoning from Pass 1 AND Nemotron's visual
# description from /detect. It produces the authoritative JSON verdict.
# ---------------------------------------------------------------------------
def _build_verdict_pass_prompt(
    category: str,
    text_reasoning: str,
    image_description: str | None,
    nemotron_detected: bool,
    nemotron_category: str,
    nemotron_confidence: float,
    image_count: int,
) -> str:
    if image_description and image_description.strip():
        photo_word = f"{image_count} photo{'s' if image_count > 1 else ''}"
        if nemotron_detected:
            det_line = f"Detected issue : Yes — {nemotron_category} (confidence {nemotron_confidence:.0%})"
        else:
            det_line = "Detected issue : No road issue detected in the image(s)"
        image_block = (
            f"IMAGE ANALYSIS — Nemotron examined {photo_word}:\n"
            f"  {det_line}\n"
            f"  Visual reasoning: {image_description.strip()}"
        )
    else:
        image_block = "IMAGE ANALYSIS: No image was submitted or could not be analyzed."

    return f"""You are a smart city road validator making a FINAL decision.
You have two independent analyses of the same citizen report. Read both carefully.

── TEXT ANALYSIS (what the citizen reported) ──────────────────────────────
{text_reasoning.strip()}

── {image_block}

───────────────────────────────────────────────────────────────────────────
Based on BOTH analyses above, give your final verdict.

Decision rules:
- TEXT and IMAGE agree on the same issue → high confidence (0.82–0.95)
- TEXT and IMAGE disagree (different issue types) → valid=true, confidence 0.50–0.70, explain mismatch in reason
- IMAGE shows no road issue → confidence 0.40–0.60, mention lack of visual confirmation
- TEXT is clear spam/nonsense AND image shows nothing → valid=false, confidence below 0.25
- TEXT is plausible but no image context → moderate confidence (0.60–0.75)
- If valid=false → confidence MUST be below 0.30

Priority levels:
- CRITICAL: immediate danger (sinkhole, collapsed road, open manhole in traffic, complete blockage)
- HIGH: serious hazard (large pothole, fallen tree blocking road, exposed wires)
- MEDIUM: significant but not immediately dangerous (broken lamppost, cracked road, raised manhole)
- LOW: minor inconvenience (small crack, faded markings, slightly uneven surface)

Reply with ONLY this JSON, no other text:
{{"valid": true, "confidence": 0.88, "reason": "1–2 sentence summary combining both text and image evidence.", "priority": "HIGH"}}

Now respond for the report above:"""


# ---------------------------------------------------------------------------
# /analyze — Two-pass pipeline
#
# Step 1 → Nemotron /detect  (already done by Java backend, result sent here)
# Step 2 → Qwen Pass 1       (text-only reasoning)
# Step 3 → Qwen Pass 2       (text reasoning + image reasoning → final verdict)
# ---------------------------------------------------------------------------
@app.post("/analyze", response_model=AnalyzeResponse)
async def analyze(req: AnalyzeRequest):
    try:
        # ── Pass 1: Text reasoning ───────────────────────────────────────────
        text_prompt = _build_text_pass_prompt(
            category      = req.category,
            sub_problem   = req.sub_problem,
            description   = req.description,
            still_votes   = req.still_votes,
            is_predefined = req.is_predefined,
        )

        text_resp = chat(
            model=OLLAMA_MODEL,
            messages=[{"role": "user", "content": text_prompt}],
            options={"temperature": 0.3, "num_predict": 200},
        )
        text_reasoning = text_resp.message.content.strip()

        print(f"\n{'='*60}")
        print(f"[PASS 1 — TEXT REASONING]\n{text_reasoning}")
        print(f"{'='*60}\n")

        # ── Pass 2: Final verdict ────────────────────────────────────────────
        verdict_prompt = _build_verdict_pass_prompt(
            category            = req.category,
            text_reasoning      = text_reasoning,
            image_description   = req.image_description,
            nemotron_detected   = req.nemotron_detected,
            nemotron_category   = req.nemotron_category,
            nemotron_confidence = req.nemotron_confidence,
            image_count         = req.image_count,
        )

        verdict_resp = chat(
            model=OLLAMA_MODEL,
            messages=[{"role": "user", "content": verdict_prompt}],
            options={"temperature": 0.1, "num_predict": 200},
        )
        raw = verdict_resp.message.content.strip()

        print(f"\n{'='*60}")
        print(f"[PASS 2 — FINAL VERDICT RAW]\n{raw}")
        print(f"{'='*60}\n")

        # Strip markdown fences if present
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
            raw = raw.strip()

        # Extract JSON object even if surrounded by extra text
        start = raw.find("{")
        end   = raw.rfind("}") + 1
        if start != -1 and end > start:
            raw = raw[start:end]

        data = json.loads(raw)

        allowed  = {"LOW", "MEDIUM", "HIGH", "CRITICAL"}
        raw_p    = str(data.get("priority", "MEDIUM")).upper()
        priority = raw_p if raw_p in allowed else "MEDIUM"

        valid      = bool(data.get("valid", True))
        confidence = float(data.get("confidence", 0.7))

        # Safety net: invalid reports must never carry high confidence
        if not valid and confidence > 0.28:
            confidence = 0.25

        print(f"[FINAL] valid={valid} confidence={confidence} priority={priority}")

        return AnalyzeResponse(
            valid      = valid,
            confidence = confidence,
            reason     = str(data.get("reason", "Validated by AI.")),
            priority   = priority,
        )

    except json.JSONDecodeError:
        return AnalyzeResponse(
            valid=True, confidence=0.6,
            reason="AI response could not be parsed — using defaults.",
            priority="MEDIUM"
        )
    except Exception as e:
        err = str(e)
        if "connection refused" in err.lower() or "connect" in err.lower():
            detail = f"Ollama is not running. Start it with: ollama serve  (error: {err})"
        else:
            detail = f"AI analysis failed: {err}"
        print(f"[ERROR] /analyze failed: {detail}")
        raise HTTPException(status_code=500, detail=detail)


# ---------------------------------------------------------------------------
# /detect — Nemotron (NVIDIA) image analysis
# ---------------------------------------------------------------------------
@app.post("/detect", response_model=DetectResponse)
async def detect(req: DetectRequest):
    urls = req.image_urls if req.image_urls else ([req.image_url] if req.image_url else [])
    if not urls:
        raise HTTPException(status_code=400, detail="Provide image_url or image_urls")
    return await _detect_nemotron(urls)


# ---------------------------------------------------------------------------
# Nemotron detector
# ---------------------------------------------------------------------------
async def _detect_nemotron(urls: list[str]) -> DetectResponse:
    if nvidia_client is None:
        raise HTTPException(status_code=503, detail="NVIDIA_API_KEY not set.")

    MAX_IMAGES = 5
    urls = urls[:MAX_IMAGES]

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/120.0.0.0 Safari/537.36"
    }

    encoded_images = []
    for url in urls:
        try:
            with httpx.Client(timeout=15, headers=headers, follow_redirects=True) as http:
                resp = http.get(url)
                resp.raise_for_status()
            encoded_images.append(base64.b64encode(resp.content).decode("utf-8"))
        except Exception as e:
            print(f"[WARNING] Nemotron skipped image {url}: {e}")

    if not encoded_images:
        raise HTTPException(status_code=400, detail="Could not download any of the provided images.")

    img_count = len(encoded_images)

    if img_count == 1:
        photo_ref        = "this road photo"
        desc_instruction = "Describe in one sentence what you see in the image."
    else:
        photo_ref        = f"these {img_count} road photos"
        desc_instruction = (
            f"You are given {img_count} photos of the same report. "
            f"Describe in one sentence the overall road condition visible across the photos."
        )

    prompt = f"""Look at {photo_ref} carefully.

{desc_instruction} Be specific about the road condition, damage type, and severity.

Then identify if any of these road issues are visible:
- pothole (hole or depression in road surface)
- manhole (manhole cover — open, broken, raised, or sunken)
- lamppost (damaged or fallen street lamp or pole)
- speedBump (damaged or missing speed bump)
- treeInRoad (fallen tree or branch blocking road)
- brokenRoad (cracked, broken, or damaged road surface)

Reply with ONLY this JSON, nothing else:
{{"detected": true, "category": "pothole", "confidence": 0.87, "image_description": "A large pothole approximately 40cm wide is visible in the center lane, with deep damage and jagged edges exposing the road base."}}

If no road issue is visible:
{{"detected": false, "category": "other", "confidence": 0.0, "image_description": "The image shows a normal road surface with no visible damage or road issues."}}"""

    content = [{"type": "text", "text": prompt}]
    for img_b64 in encoded_images:
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}})

    try:
        completion = nvidia_client.chat.completions.create(
            model=NVIDIA_MODEL,
            messages=[{"role": "user", "content": content}],
            temperature=0.2,
            top_p=0.9,
            max_tokens=200,
            extra_body={"chat_template_kwargs": {"enable_thinking": False}},
            stream=True,
        )

        raw = ""
        for chunk in completion:
            if not chunk.choices:
                continue
            if chunk.choices[0].delta.content:
                raw += chunk.choices[0].delta.content

        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
            raw = raw.strip()

        start = raw.find("{")
        end   = raw.rfind("}") + 1
        if start != -1 and end > start:
            raw = raw[start:end]

        data = json.loads(raw)

        detected          = bool(data.get("detected", False))
        category          = str(data.get("category", "other"))
        confidence        = float(data.get("confidence", 0.0))
        image_description = str(data.get("image_description", "")).strip()

        if category not in VALID_CATEGORIES:
            category = "other"

        if not detected and not image_description:
            image_description = (
                "No road infrastructure issue was detected in the submitted image(s). "
                "The image does not appear to show any road damage or hazard."
            )

        print(f"[INFO] Nemotron /detect → detected={detected} category={category} "
              f"confidence={confidence} description='{image_description}'")

        return DetectResponse(
            detected=detected, category=category, confidence=confidence,
            all_detections=[{"category": category, "confidence": confidence}] if detected else [],
            image_description=image_description,
        )

    except json.JSONDecodeError:
        return DetectResponse(detected=False, category="other", confidence=0.0,
                              all_detections=[],
                              image_description="Image analysis was inconclusive — no road issue could be identified.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Nemotron image analysis failed: {str(e)}")


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {
        "status":         "ok",
        "llm":            f"ollama/{OLLAMA_MODEL}",
        "detector":       "nemotron",
        "image_analysis": f"nemotron/{NVIDIA_MODEL} (key: {'configured' if NVIDIA_API_KEY else 'MISSING'})",
        "flow":           "Nemotron(/detect) → Qwen-Pass1(text) → Qwen-Pass2(text+image) → verdict",
    }
