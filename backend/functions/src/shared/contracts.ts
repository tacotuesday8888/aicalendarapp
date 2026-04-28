import { z } from "zod";

const looseObject = z.object({}).passthrough();
const userIDSchema = z.string().trim().min(1).max(128);
const assistantMessageSchema = z.string().trim().min(1).max(2000);
const reflectionPromptSchema = z.string().trim().min(1).max(4000);
const syllabusTextSchema = z.string().trim().min(1).max(120000);
const sourceNameSchema = z.string().trim().min(1).max(256);

export const assistantRequestSchema = z.object({
  userID: userIDSchema,
  message: assistantMessageSchema,
  snapshot: looseObject,
  goals: z.array(looseObject).max(25)
});

export const goalPlanRequestSchema = z.object({
  userID: userIDSchema,
  goal: looseObject,
  timelineWeeks: z.number().int().positive().max(52)
});

export const vibeFeedbackRequestSchema = z.object({
  userID: userIDSchema,
  prompt: reflectionPromptSchema
});

export const assistantDraftCommitSchema = z.object({
  userID: userIDSchema,
  action: looseObject.extend({
    id: z.string().trim().min(1).max(128),
    kind: z.string().trim().min(1).max(64)
  })
});

export const importTextRequestSchema = z.object({
  userID: userIDSchema,
  text: syllabusTextSchema
});

export const importFileRequestSchema = z.object({
  userID: userIDSchema,
  sourceName: sourceNameSchema,
  uploadedPath: z.string().trim().max(1024).optional().nullable(),
  extractedText: z.string().trim().max(120000).default("")
});

export const importCommitSchema = z.object({
  userID: userIDSchema,
  job: looseObject.extend({
    id: z.string().trim().min(1).max(128),
    extractedCourses: z.array(looseObject).default([]),
    extractedAssignments: z.array(looseObject).default([])
  })
});

export const deleteImportSchema = z.object({
  userID: userIDSchema,
  job: looseObject.extend({
    id: z.string().trim().min(1).max(128),
    uploadedFilePath: z.string().trim().max(1024).optional().nullable()
  })
});

export const userJobRequestSchema = z.object({
  userID: userIDSchema
});

export type AssistantRequest = z.infer<typeof assistantRequestSchema>;
export type GoalPlanRequest = z.infer<typeof goalPlanRequestSchema>;
export type VibeFeedbackRequest = z.infer<typeof vibeFeedbackRequestSchema>;
export type AssistantDraftCommitRequest = z.infer<typeof assistantDraftCommitSchema>;
export type ImportTextRequest = z.infer<typeof importTextRequestSchema>;
export type ImportFileRequest = z.infer<typeof importFileRequestSchema>;
export type ImportCommitRequest = z.infer<typeof importCommitSchema>;
export type DeleteImportRequest = z.infer<typeof deleteImportSchema>;
export type UserJobRequest = z.infer<typeof userJobRequestSchema>;
