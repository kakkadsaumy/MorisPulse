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