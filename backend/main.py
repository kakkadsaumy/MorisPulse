from dotenv import load_dotenv
load_dotenv()
import os
import re
import json
import base64
import uuid
from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from google import genai
from google.genai import types
from openai import OpenAI

from supabase import create_client, Client

url: str = os.environ.get("SUPABASE_URL")
key: str = os.environ.get("SUPABASE_KEY")
supabase: Client = create_client(url, key)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

client = genai.Client(api_key=os.environ.get("GOOGLE_API_KEY"))

MODEL = "gemma-4-26b-a4b-it"
SECRET_KEY = os.environ.get("SECRET_KEY", "hackathon123")

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
LOCAL_MODEL = os.environ.get("LOCAL_MODEL", "gemma4:e4b-it-q4_K_M")
local_client = OpenAI(base_url=f"{OLLAMA_HOST}/v1", api_key="ollama")

conversations = {}
locations = {}
turn_counts = {}

MAX_TURNS = 4


class MessageBody(BaseModel):
    message: str
    lat: float
    lng: float
    image_base64: str | None = None


class InfoBody(BaseModel):
    info: str
    image_base64: str | None = None


class StatusBody(BaseModel):
    status: str


@app.get("/health")
def health():
    return {"status": "a-ok"}


ask_followup_tool = {
    "name": "ask_followup",
    "description": "Ask the citizen a clarifying question before finalizing the report. Never ask them to rate severity themselves.",
    "parameters": {
        "type": "object",
        "properties": {"question": {"type": "string"}},
        "required": ["question"],
    },
}

submit_report_tool = {
    "name": "submit_report",
    "description": "Finalize and submit the complaint as a structured report. You determine severity yourself.",
    "parameters": {
        "type": "object",
        "properties": {
            "category": {"type": "string"},
            "severity": {"type": "integer"},
            "summary": {"type": "string"},
        },
        "required": ["category", "severity", "summary"],
    },
}

local_tools = [
    {"type": "function", "function": {
        "name": "ask_followup",
        "description": ask_followup_tool["description"],
        "parameters": ask_followup_tool["parameters"],
    }},
    {"type": "function", "function": {
        "name": "submit_report",
        "description": submit_report_tool["description"],
        "parameters": submit_report_tool["parameters"],
    }},
]


def build_prompt(history, force_submit=False):
    convo_text = "\n".join(f"{m['role']}: {m['text']}" for m in history)
    force_note = (
        "\nThis conversation has gone on long enough — call submit_report now with your best-effort values, even if some details are imperfect."
        if force_submit else ""
    )
    return f"""You are the intake assistant for MorisPulse AI, a Mauritian civic-issue
reporting platform. Citizens may write in French or English - respond in the same
language they used.

Location is captured automatically via GPS - never ask the citizen for coordinates,
addresses, or landmarks.

You determine the severity (1-5) yourself, based on the danger, scale, and urgency
described. Never ask the citizen what severity they'd rate it - that is your job, not theirs.

Ask a follow-up question only if the category or nature of the issue itself is unclear.
Don't ask more than 1-2 follow-up questions total - prefer to submit with a reasonable
estimate over interrogating the citizen.{force_note}

Conversation so far:
{convo_text}"""


def distance(lat1, lng1, lat2, lng2):
    return ((lat1 - lat2) ** 2 + (lng1 - lng2) ** 2) ** 0.5


def find_duplicate(category, lat, lng, threshold=0.0045):
    try:
        response = (
            supabase.table("reports")
            .select("*")
            .eq("category", category)
            .neq("status", "resolved")
            .execute()
        )
    except Exception:
        return None
    for r in response.data:
        loc = r.get("location") or {}
        if distance(loc.get("lat", 0.0), loc.get("lng", 0.0), lat, lng) < threshold:
            return r
    return None


def _extract_function_call(response):
    if response.candidates and response.candidates[0].content.parts:
        for part in response.candidates[0].content.parts:
            if part.function_call is not None:
                return part.function_call
    return None


def _call_gemma_api(contents):
    """Primary path: Google's hosted Gemma API."""
    response = client.models.generate_content(
        model=MODEL,
        contents=contents,
        config=types.GenerateContentConfig(
            tools=[types.Tool(function_declarations=[ask_followup_tool, submit_report_tool])]
        ),
    )
    call = _extract_function_call(response)
    if call is None:
        return {"kind": "text", "text": response.text}
    return {"kind": "call", "name": call.name, "args": dict(call.args)}


def _call_gemma_local(history, force_submit=False):
    """Fallback path: local E4B via Ollama on your laptop, reached over LAN."""
    prompt = build_prompt(history, force_submit=force_submit)
    response = local_client.chat.completions.create(
        model=LOCAL_MODEL,
        messages=[{"role": "user", "content": prompt}],
        tools=local_tools,
        tool_choice="auto",
    )
    choice = response.choices[0].message
    if choice.tool_calls:
        call = choice.tool_calls[0].function
        args = json.loads(call.arguments or "{}")
        return {"kind": "call", "name": call.name, "args": args}
    return {"kind": "text", "text": choice.content}


@app.post("/report/{report_id}/message")
def send_message(report_id: str, body: MessageBody):
    history = conversations.setdefault(report_id, [])
    locations[report_id] = {"lat": body.lat, "lng": body.lng}
    turn_counts[report_id] = turn_counts.get(report_id, 0) + 1

    history.append({"role": "citizen", "text": body.message})
    force_submit = turn_counts[report_id] >= MAX_TURNS

    contents = [build_prompt(history, force_submit=force_submit)]
    if body.image_base64:
        image_bytes = base64.b64decode(body.image_base64)
        contents.append(types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"))

    used_fallback = False
    try:
        result = _call_gemma_api(contents)
    except Exception as e:
        print(f"[Gemini API error, falling back to local] {type(e).__name__}: {e}")
        try:
            result = _call_gemma_local(history, force_submit=force_submit)
            used_fallback = True
        except Exception as e2:
            print(f"[Local fallback also failed] {type(e2).__name__}: {e2}")
            return {"type": "error", "message": "Something went wrong, please try again."}

    if result["kind"] == "text":
        history.append({"role": "assistant", "text": result["text"]})
        return {"type": "text", "message": result["text"], "fallback_used": used_fallback}

    name, args = result["name"], result["args"]

    if name == "ask_followup":
        question = args["question"]
        history.append({"role": "assistant", "text": question})
        return {"type": "question", "question": question, "fallback_used": used_fallback}

    if name == "submit_report":
        loc = locations.get(report_id, {"lat": 0.0, "lng": 0.0})
        lat, lng = loc["lat"], loc["lng"]

        dup = find_duplicate(args["category"], lat, lng)
        if dup:
            new_count = dup["confirmations"] + 1
            try:
                supabase.table("reports").update(
                    {"confirmations": new_count}
                ).eq("id", dup["id"]).execute()
            except Exception:
                pass
            dup["confirmations"] = new_count
            history.append({"role": "assistant", "text": f"Matched existing report #{dup['id']}"})
            return {"type": "duplicate", "report": dup, "fallback_used": used_fallback}

        rid = str(uuid.uuid4())
        report = {
            "id": rid,
            "category": args["category"],
            "severity": args["severity"],
            "summary": args["summary"],
            "location": {"lat": lat, "lng": lng},
            "status": "open",
            "confirmations": 1,
            "image_url": None,
            "history": [],
        }
        try:
            supabase.table("reports").insert(report).execute()
        except Exception:
            raise HTTPException(503, "Could not save report to database.")

        history.append({"role": "assistant", "text": f"Submitted as report #{rid}"})
        return {"type": "submitted", "report": report, "fallback_used": used_fallback}


@app.get("/dashboard")
def dashboard():
    try:
        response = supabase.table("reports").select("*").execute()
    except Exception:
        raise HTTPException(503, "Could not fetch reports from database.")
    return response.data


@app.post("/report/{report_id}/confirm")
def confirm(report_id: str):
    try:
        existing = supabase.table("reports").select("*").eq("id", report_id).execute()
    except Exception:
        raise HTTPException(503, "Could not reach database.")
    if not existing.data:
        raise HTTPException(404, "Report not found")

    report = existing.data[0]
    new_count = report["confirmations"] + 1
    try:
        supabase.table("reports").update({"confirmations": new_count}).eq("id", report_id).execute()
    except Exception:
        raise HTTPException(503, "Could not update report.")

    report["confirmations"] = new_count
    return report


@app.post("/report/{report_id}/add-info")
def add_info(report_id: str, body: InfoBody):
    try:
        existing = supabase.table("reports").select("*").eq("id", report_id).execute()
    except Exception:
        raise HTTPException(503, "Could not reach database.")
    if not existing.data:
        raise HTTPException(404, "Report not found")
    report = existing.data[0]

    prompt_text = f"""Original report category: {report['category']}, summary: {report['summary']}, current severity: {report['severity']}.
New info from a volunteer: "{body.info}"."""

    contents = [prompt_text]

    if body.image_base64:
        image_bytes = base64.b64decode(body.image_base64)
        contents.append(types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"))
        contents[0] += f"""
Also examine the attached image. Does it plausibly show a real {report['category']}
issue matching this report, and not something unrelated or fake? Respond with ONLY JSON:
{{"severity": <int 1-5>, "note": "<short update>", "image_valid": <true/false>, "image_reason": "<why>"}}"""
    else:
        contents[0] += """
Respond with ONLY JSON: {"severity": <int 1-5>, "note": "<short update>"}"""

    try:
        response = client.models.generate_content(model=MODEL, contents=contents)
        raw_text = response.text
    except Exception:
        raise HTTPException(503, "Model unavailable, please try again.")

    cleaned = re.sub(r"^```(json)?|```$", "", raw_text.strip(), flags=re.MULTILINE).strip()

    try:
        result = json.loads(cleaned)
    except json.JSONDecodeError:
        result = {"severity": report["severity"], "note": body.info, "image_valid": True}

    if not result.get("image_valid", True):
        raise HTTPException(400, f"Image rejected: {result.get('image_reason', 'does not match report')}")

    report["severity"] = result["severity"]
    updated_history = (report.get("history") or []) + [{
        "note": result["note"],
        "severity": result["severity"],
        "image_valid": result.get("image_valid", True),
    }]
    report["history"] = updated_history

    try:
        supabase.table("reports").update({
            "severity": result["severity"],
            "history": updated_history,
        }).eq("id", report_id).execute()
    except Exception:
        raise HTTPException(503, "Could not update report.")

    return report


@app.patch("/report/{report_id}/status")
def update_status(report_id: str, body: StatusBody, request: Request):
    if request.headers.get("x-secret-key") != SECRET_KEY:
        raise HTTPException(401, "Unauthorized")

    try:
        existing = supabase.table("reports").select("*").eq("id", report_id).execute()
    except Exception:
        raise HTTPException(503, "Could not reach database.")
    if not existing.data:
        raise HTTPException(404, "Report not found")

    try:
        supabase.table("reports").update({"status": body.status}).eq("id", report_id).execute()
    except Exception:
        raise HTTPException(503, "Could not update report.")

    report = existing.data[0]
    report["status"] = body.status
    return report