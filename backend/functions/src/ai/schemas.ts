import { z } from "genkit";

export const aiWorkflowSchema = z.enum([
  "assistant_chat",
  "goal_plan_generation",
  "vibe_feedback",
  "syllabus_import"
]);

const looseObjectSchema = z.record(z.any()).default({});

export const assistantChatPayloadSchema = z.object({
  message: z.string().trim().min(1).max(2000),
  timezone: z.string().trim().min(1).max(64),
  currentScreen: z.string().trim().max(128).optional().nullable(),
  date: z.string().trim().max(64).optional().nullable(),
  contextHints: looseObjectSchema
});

export const assistantDraftActionSchema = z.object({
  type: z.enum(["goal_plan", "planner_adjustment"]),
  title: z.string().trim().min(1),
  dueAt: z.string().trim().nullable(),
  reason: z.string().trim().min(1)
});

export const assistantChatResultSchema = z.object({
  message: z.string().trim().min(1),
  draftActions: z.array(assistantDraftActionSchema),
  degraded: z.boolean().optional()
});

export const goalDetailsSchema = z.object({
  title: z.string().trim().min(1).max(160),
  description: z.string().trim().max(2000).default("")
});

export const goalPlanGenerationPayloadSchema = z.object({
  goalID: z.string().trim().min(1).max(128).optional().nullable(),
  goal: goalDetailsSchema.optional().nullable(),
  timelineWeeks: z.number().int().positive().max(104),
  startDate: z.string().trim().min(1).max(64),
  timezone: z.string().trim().min(1).max(64)
});

export const goalMilestoneSchema = z.object({
  title: z.string().trim().min(1),
  dueDate: z.string().trim().min(1),
  description: z.string().trim().min(1)
});

export const goalNextActionSchema = z.object({
  title: z.string().trim().min(1),
  estimatedMinutes: z.number().int().positive(),
  priority: z.enum(["low", "medium", "high"])
});

export const goalPlanGenerationResultSchema = z.object({
  summary: z.string().trim().min(1),
  milestones: z.array(goalMilestoneSchema),
  nextActions: z.array(goalNextActionSchema).min(3).max(5),
  degraded: z.boolean().optional()
});

export const vibeFeedbackPayloadSchema = z.object({
  reflectionText: z.string().trim().min(1).max(4000),
  timezone: z.string().trim().min(1).max(64),
  recentContext: looseObjectSchema.optional()
});

export const vibeFeedbackResultSchema = z.object({
  feedback: z.string().trim().min(1),
  needs_escalation: z.boolean(),
  degraded: z.boolean().optional()
});

export const syllabusImportPayloadSchema = z.object({
  extractedText: z.string().trim().min(1).max(120000),
  currentDate: z.string().trim().max(64).optional().nullable(),
  timezone: z.string().trim().min(1).max(64),
  sourceName: z.string().trim().max(256).optional().nullable(),
  uploadedFilePath: z.string().trim().max(1024).optional().nullable()
});

export const syllabusAssignmentSchema = z.object({
  title: z.string().trim().min(1),
  type: z.string().trim().nullable(),
  dueDate: z.string().trim().nullable(),
  confidence: z.enum(["low", "medium", "high"]),
  sourceText: z.string().trim().min(1)
});

export const syllabusCourseSchema = z.object({
  name: z.string().trim().min(1),
  instructor: z.string().trim().nullable(),
  assignments: z.array(syllabusAssignmentSchema)
});

export const syllabusWarningSchema = z.object({
  message: z.string().trim().min(1),
  sourceText: z.string().trim().nullable()
});

export const syllabusImportResultSchema = z.object({
  courses: z.array(syllabusCourseSchema),
  warnings: z.array(syllabusWarningSchema),
  degraded: z.boolean().optional()
});

export const aiRunRequestSchema = z.discriminatedUnion("workflow", [
  z.object({
    workflow: z.literal("assistant_chat"),
    payload: assistantChatPayloadSchema
  }),
  z.object({
    workflow: z.literal("goal_plan_generation"),
    payload: goalPlanGenerationPayloadSchema
  }),
  z.object({
    workflow: z.literal("vibe_feedback"),
    payload: vibeFeedbackPayloadSchema
  }),
  z.object({
    workflow: z.literal("syllabus_import"),
    payload: syllabusImportPayloadSchema
  })
]);

export type AIWorkflow = z.infer<typeof aiWorkflowSchema>;
export type AIRunRequest = z.infer<typeof aiRunRequestSchema>;
export type AssistantChatPayload = z.infer<typeof assistantChatPayloadSchema>;
export type AssistantChatResult = z.infer<typeof assistantChatResultSchema>;
export type GoalPlanGenerationPayload = z.infer<typeof goalPlanGenerationPayloadSchema>;
export type GoalPlanGenerationResult = z.infer<typeof goalPlanGenerationResultSchema>;
export type VibeFeedbackPayload = z.infer<typeof vibeFeedbackPayloadSchema>;
export type VibeFeedbackResult = z.infer<typeof vibeFeedbackResultSchema>;
export type SyllabusImportPayload = z.infer<typeof syllabusImportPayloadSchema>;
export type SyllabusImportResult = z.infer<typeof syllabusImportResultSchema>;
