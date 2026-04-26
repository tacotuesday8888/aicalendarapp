from app.prompts.base import BASE_SYSTEM_PROMPT


SYLLABUS_IMPORT_PROMPT = """
Extract structured course and assignment information from syllabus text.
Extract only information explicitly present in the syllabus.
Do not invent dates, assignments, instructors, or course names.
Use ISO8601 dates when dates are clear.
Use null for ambiguous or missing dates.
Add warnings for ambiguous dates, missing years, repeated assignments, unclear grading categories, or possible schedule conflicts.
Return JSON with courses and warnings.
""".strip()


def build_syllabus_import_instructions() -> str:
    return f"{BASE_SYSTEM_PROMPT}\n\n{SYLLABUS_IMPORT_PROMPT}"
