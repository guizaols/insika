# Studio interface refinement

Goal: apply the approved Models and Facts visual language throughout Studio, improving the actual reading, decision, and editing flows.
Architecture: retain Roda/ERB, existing CSS tokens, Stimulus controllers, routes, authorization, and stores. Use native details for secondary information. No new dependency or component framework.
Spec: the user-approved four-stage plan in this task, executed on request.

## Global constraints

Preserve all existing actions, scope, filters, selection, CSRF protection, dirty guards, validation, and streaming. Keep errors and pending decisions visible. Escape stored content. Use English product copy. Verify desktop/mobile, long content, keyboard, relevant specs, the full Ruby suite, and front-end build/tests. Do not mutate the real database during QA. Build and commit assets/dist.

## Tasks

- [x] Review: Knowledge, Approvals, Harvest, Refinement. Content and evidence before editing; understandable decisions; technical details secondary.
- [x] Operation: Chats/Sessions, Tasks, Customers, Follow-ups. Clear status, history, next action; preserve navigation context.
- [x] Configuration: Agents, Tools, Skills, MCP, Settings, System files, Playground. Group fields by purpose; clarify saving and advanced settings.
- [x] Reports: Home, Funnel, Evals, Parity, Artifacts. Compact summaries, consistent filters/tables, useful empty states.
- [x] Shared visual integration: reuse tokens and existing patterns, responsive layout, no redundant abstractions.
- [x] Verification: meaningful regression specs, visual QA, build, full suite, independent review, reviewable pull requests.

Delivery: one integrated pull request, with separate commits for shared styles, review, operation, configuration, and reports. Preserve the original main checkout and existing untracked user plans.

Verification: 5,684 Ruby examples, 409 focused Studio examples, and 53 front-end tests passed. Desktop (1500px) and mobile (390px) page checks found no document overflow. Knowledge save, dirty navigation, keyboard disclosures, and restore were exercised against an in-memory preview. Independent review findings were fixed.
