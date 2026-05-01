# Browser App Refactor Plan (1500-Line Hard Limit)

## Rule
- Every source file in `src/browser` must stay at or below **1500 lines**.

## Scope
- Replace the current monolithic `app.lua` split-by-parts approach with **feature-grouped modules**.
- Keep behavior stable while improving maintainability and ownership boundaries.
- Keep every source file in `src/browser` below 1500, including `lib/content.lua`.

## Implemented Folder Structure
- `app/features/` feature-ordered browser runtime slices
  - `01_bootstrap.lua`
  - `02_settings_state.lua`
  - `03_tabs_modal_render.lua`
  - `04_page_actions_forms.lua`
  - `05_navigation_applets.lua`
  - `06_input_handlers.lua`
  - `07_runtime_loop.lua`
- `lib/content-features/` feature-grouped content engine slices
  - `01_style_and_css.lua`
  - `02_writer.lua`
  - `03_form_controls.lua`
  - `04_render_pipeline.lua`

## Line Budget (Proof of Limit Approval)
- `app.lua` (entry loader): **59**
- `app/features/01_bootstrap.lua`: **655**
- `app/features/02_settings_state.lua`: **832**
- `app/features/03_tabs_modal_render.lua`: **1136**
- `app/features/04_page_actions_forms.lua`: **1032**
- `app/features/05_navigation_applets.lua`: **799**
- `app/features/06_input_handlers.lua`: **832**
- `app/features/07_runtime_loop.lua`: **356**
- `lib/content.lua` (entry loader): **56**
- `lib/content-features/01_style_and_css.lua`: **606**
- `lib/content-features/02_writer.lua`: **428**
- `lib/content-features/03_form_controls.lua`: **455**
- `lib/content-features/04_render_pipeline.lua`: **336**

All targets are strictly below 1500 lines.

## Execution Steps
1. Split `app.lua` into grouped runtime feature files under `app/features/`.
2. Replace `app.lua` with a thin ordered loader that compiles feature files as one chunk.
3. Split `lib/content.lua` into grouped engine feature files under `lib/content-features/`.
4. Replace `lib/content.lua` with a thin ordered loader that compiles feature files as one chunk.
5. Verify line counts for all source files.

## Acceptance Criteria
- No source file in `src/browser` exceeds 1500 lines.
- `app.lua` no longer uses anonymous `app.partNN.lua` segmentation.
- Browser and content engine are feature-grouped with production-ready folder structure.
