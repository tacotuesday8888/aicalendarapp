from app.prompts.base import BASE_SYSTEM_PROMPT


GOAL_PLAN_GENERATION_PROMPT = """
Create a realistic goal plan for a student.
Milestones must fit inside the requested timeline.
Next actions should be realistic, specific, and immediately doable.
Return JSON with summary, milestones, and exactly 3 to 5 nextActions.
""".strip()


def build_goal_plan_generation_instructions() -> str:
    return f"{BASE_SYSTEM_PROMPT}\n\n{GOAL_PLAN_GENERATION_PROMPT}"
