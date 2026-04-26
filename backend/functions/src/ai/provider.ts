export interface AIProviderRequest {
  system: string;
  user: string;
}

export interface AIProviderResult {
  text: string;
}

export interface AIProvider {
  complete(request: AIProviderRequest): Promise<AIProviderResult>;
}

export const AI_DISABLED_MESSAGE = "AI setup is not enabled yet. Choose an AI provider to turn on this feature.";

export function isAIDisabledResponse(text: string): boolean {
  return text.includes(AI_DISABLED_MESSAGE);
}

class StubProvider implements AIProvider {
  async complete(request: AIProviderRequest): Promise<AIProviderResult> {
    const combinedPrompt = `${request.system}\n${request.user}`;

    if (combinedPrompt.includes("\"draftActions\"")) {
      return {
        text: JSON.stringify({
          message: `${AI_DISABLED_MESSAGE} You can keep using goals, calendar, check-ins, and the rest of the planner while AI is deferred.`,
          draftActions: []
        })
      };
    }

    if (combinedPrompt.includes("\"timelineWeeks\"")) {
      return {
        text: JSON.stringify({
          summary: `${AI_DISABLED_MESSAGE} Goal plans will be available after AI is configured.`,
          checkpoints: [],
          nextActions: []
        })
      };
    }

    return {
      text: AI_DISABLED_MESSAGE
    };
  }
}

class OpenAICompatibleProvider implements AIProvider {
  constructor(
    private readonly endpoint: string,
    private readonly apiKey: string,
    private readonly model: string
  ) {}

  async complete(request: AIProviderRequest): Promise<AIProviderResult> {
    const response = await fetch(this.endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`
      },
      body: JSON.stringify({
        model: this.model,
        temperature: 0.2,
        messages: [
          {
            role: "system",
            content: request.system
          },
          {
            role: "user",
            content: request.user
          }
        ]
      })
    });

    if (!response.ok) {
      throw new Error(`AI provider request failed with status ${response.status}.`);
    }

    const payload = (await response.json()) as {
      choices?: Array<{
        message?: { content?: string };
        text?: string;
      }>;
      text?: string;
    };

    return {
      text:
        payload.choices?.[0]?.message?.content ??
        payload.choices?.[0]?.text ??
        payload.text ??
        "No response returned by provider."
    };
  }
}

class JSONPromptProvider implements AIProvider {
  constructor(
    private readonly endpoint: string,
    private readonly apiKey: string,
    private readonly model: string
  ) {}

  async complete(request: AIProviderRequest): Promise<AIProviderResult> {
    const response = await fetch(this.endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`
      },
      body: JSON.stringify({
        model: this.model,
        system: request.system,
        prompt: request.user
      })
    });

    if (!response.ok) {
      throw new Error(`AI provider request failed with status ${response.status}.`);
    }

    const payload = (await response.json()) as { text?: string };
    return { text: payload.text ?? "No response returned by provider." };
  }
}

export function createAIProvider(): AIProvider {
  const provider = process.env.AI_PROVIDER ?? "stub";
  const endpoint = process.env.AI_ENDPOINT;
  const apiKey = process.env.AI_API_KEY;
  const model = process.env.AI_MODEL ?? "gemma";

  if (endpoint && apiKey && provider === "openai-compatible") {
    return new OpenAICompatibleProvider(endpoint, apiKey, model);
  }

  if (endpoint && apiKey && provider === "json-prompt") {
    return new JSONPromptProvider(endpoint, apiKey, model);
  }

  return new StubProvider();
}
