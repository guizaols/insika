// Fixture HERMÉTICO (espelha o formato do plugin OpenClaw consumer-tools-dev):
// registra 3 tools representativas p/ o spec do conversor. NÃO depende da fonte
// externa. `search-faq` também existe como arquivo mas NÃO é registrado aqui —
// prova que o conversor só emite as tools de api.registerTool(...).
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
