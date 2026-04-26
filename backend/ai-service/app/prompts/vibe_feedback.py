from app.prompts.base import BASE_SYSTEM_PROMPT


VIBE_FEEDBACK_PROMPT = """
Give one short, supportive, grounded, non-clinical paragraph.
Do not diagnose.
Suggest one small next step.
If the reflection indicates self-harm, suicidal ideation, or immediate danger, respond with safe urgent guidance and set needs_escalation to true.
Return JSON with feedback and needs_escalation.
""".strip()


def build_vibe_feedback_instructions() -> str:
    return f"{BASE_SYSTEM_PROMPT}\n\n{VIBE_FEEDBACK_PROMPT}"
