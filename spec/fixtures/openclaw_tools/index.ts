// HERMETIC fixture (mirrors the format of an OpenClaw tools plugin):
// registers representative tools for the converter spec. It does NOT depend on
// the external source. `search-faq` also exists as a file but is NOT registered
// here — proving the converter only emits tools from api.registerTool(...).
import { createSearchProductsTool } from "./tools/search-products.js";
import { createSearchFaqTool } from "./tools/search-faq.js";
import { createSendFinalizeButtonTool } from "./tools/send-finalize-button.js";
import { createDormantTool } from "./tools/dormant.js";
import { createExoticTool } from "./tools/exotic.js";

const plugin = {
  id: "fixture-tools",
  register(api: any) {
    const resolveCtx = (ctx: any) => ctx;
    api.registerTool((ctx: any) => createSearchProductsTool(resolveCtx(ctx)));
    api.registerTool((ctx: any) => createSearchFaqTool(resolveCtx(ctx)));
    api.registerTool((ctx: any) => createSendFinalizeButtonTool(resolveCtx(ctx)));
    // Registered, but its params have no equivalent in the safe subset -> the converter
    // SKIPS it (and reports it) instead of emitting a guessed schema.
    api.registerTool((ctx: any) => createExoticTool(resolveCtx(ctx)));
    // createDormantTool é importado mas NÃO registrado -> não entra no manifesto.
  },
};

export default plugin;
