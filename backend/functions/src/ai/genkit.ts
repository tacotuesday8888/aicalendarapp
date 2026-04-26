import { genkit } from "genkit";
import { vertexAI } from "@genkit-ai/google-genai";

import { getAIMaxOutputTokens, getAIModelName, getAIVertexLocation } from "./config.js";

export const genkitAI = genkit({
  plugins: [vertexAI({ location: getAIVertexLocation() })]
});

export function configuredVertexModel() {
  return vertexAI.model(getAIModelName());
}

export function defaultGenerationConfig() {
  return {
    temperature: 0.2,
    maxOutputTokens: getAIMaxOutputTokens()
  };
}
