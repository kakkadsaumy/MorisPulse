import os
import re
import json
import base64
from fastapi import FastAPI, Request, HTTPException
from pydantic import BaseModel
from google import genai
from google.genai import types

app = FastAPI()
client = genai.Client(api_key=os.environ.get("GOOGLE_API_KEY", "dummy-key"))

conversations = {}  
reports = {}       
next_id = [1]

class MessageBody(BaseModel):
    message: str

class InfoBody(BaseModel):
    info: str
    image_base64: str | None = None 

class StatusBody(BaseModel):
    status: str

@app.get("/health")
def health():
    return {"status" : "a-ok"}

ask_followup_tool = {
    "name": "ask_followup",
    "description": "Ask the citizen a clarifying question before finalizing the report.",
    "parameters": {
        "type": "object",
        "properties": {"question": {"type": "string"}},
        "required": ["question"],
    },
}

submit_report_tool = {
    "name": "submit_report",
    "description": "Finalize and submit the complaint as a structured report.",
    "parameters": {
        "type": "object",
        "properties": {
            "category": {"type": "string"},
            "severity": {"type": "integer"},
            "summary": {"type": "string"},
            "lat": {"type": "number"},
            "lng": {"type": "number"},
        },
        "required": ["category", "severity", "summary"],
    },
}