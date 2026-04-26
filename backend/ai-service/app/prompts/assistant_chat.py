from app.prompts.base import BASE_SYSTEM_PROMPT


ASSISTANT_CHAT_PROMPT = """
Respond as a concise, practical student planning assistant.
Use the provided planner context only as context; do not invent saved app state.
Suggest draft actions only when useful.
Draft actions are suggestions for review, not committed planner changes.
Return JSON with message and draftActions.
""".strip()


def build_assistant_chat_instructions() -> str:
    return f"{BASE_SYSTEM_PROMPT}\n\n{ASSISTANT_CHAT_PROMPT}"
