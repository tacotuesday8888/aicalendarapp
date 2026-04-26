import { z } from "zod";

const looseObject = z.object({}).passthrough();

export const assistantRequestSchema = z.object({
  userID: z.string().min(1),
  message: z.string().min(1),
  snapshot: looseObject,
  goals: z.array(looseObject)
});

export const goalPlanRequestSchema = z.object({
  userID: z.string().min(1),
  goal: looseObject,
  timelineWeeks: z.number().int().positive().max(52)
});

export const vibeFeedbackRequestSchema = z.object({
  userID: z.string().min(1),
  prompt: z.string().min(1)
});

export const assistantDraftCommitSchema = z.object({
  userID: z.string().min(1),
  action: looseObject.extend({
    id: z.string().min(1),
    kind: z.string().min(1)
  })
});

export const importTextRequestSchema = z.object({
  userID: z.string().min(1),
  text: z.string().min(1)
});

export const importFileRequestSchema = z.object({
  userID: z.string().min(1),
  sourceName: z.string().min(1),
  uploadedPath: z.string().optional().nullable(),
  extractedText: z.string().default("")
});

export const importCommitSchema = z.object({
  userID: z.string().min(1),
  job: looseObject.extend({
    id: z.string().min(1),
    extractedCourses: z.array(looseObject).default([]),
    extractedAssignments: z.array(looseObject).default([])
  })
});

export const deleteImportSchema = z.object({
  userID: z.string().min(1),
  job: looseObject.extend({
    id: z.string().min(1),
    uploadedFilePath: z.string().optional().nullable()
  })
});

export const userJobRequestSchema = z.object({
  userID: z.string().min(1)
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
