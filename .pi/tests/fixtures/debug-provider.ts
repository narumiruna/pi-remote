// Explicit test-only Pi provider. It never opens a network connection and is
// outside .pi/extensions, so normal project discovery cannot load it.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("debug-fixture-reload", { description: "Reload the isolated debug test runtime", handler: async (_args, ctx) => { await ctx.reload(); } });
  pi.registerProvider("pi-remote-debug-fixture", {
    api: "pi-remote-debug-fixture-api", baseUrl: "http://unused.invalid", apiKey: "local-test-only",
    models: [{ id: "local", name: "Local debug test", reasoning: false, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1024 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const calls = context.messages.at(-1)?.role === "user";
        const output: any = {
          role: "assistant", api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(), stopReason: "pending", content: [],
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        };
        stream.push({ type: "start", partial: output });
        if (calls) {
          for (const [index, operation] of ["status", "capture", "interact"].entries()) {
            const toolCall = { type: "toolCall" as const, id: `debug-fixture-${operation}`, name: `pi_remote_debug_${operation}`, arguments: operation === "interact" ? { action: "navigate", value: "overview" } : {} };
            output.content.push(toolCall);
            stream.push({ type: "toolcall_start", contentIndex: index, partial: output });
            stream.push({ type: "toolcall_end", contentIndex: index, toolCall, partial: output });
          }
          output.stopReason = "toolUse";
        } else {
          output.content.push({ type: "text", text: "Local debug fixture completed." });
          stream.push({ type: "text_start", contentIndex: 0, partial: output });
          stream.push({ type: "text_end", contentIndex: 0, content: "Local debug fixture completed.", partial: output });
          output.stopReason = "stop";
        }
        stream.push({ type: "done", reason: output.stopReason, message: output }); stream.end();
      });
      return stream;
    },
  });
}
