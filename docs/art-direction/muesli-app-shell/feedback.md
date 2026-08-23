# Feedback history

## 24-08-2026 — carry the floating language into the app, and reorganise settings

- Request: the floating indicator and meeting panel are settled; redesign the app's design
  system and UI on the same concepts, reorganise settings, research competitors first, and
  produce visual designs to review.
- Keep: the Contextual Spark palette, the 22 pt module, continuous radii, and the shipped
  0.16 / 0.26 / 0.14 s motion durations.
- Drop: the cool blue-black shell palette (`#111214` / `#161719` / `#1c1d20`), the blue default
  accent, the default circular corner curve, and the six-pane segmented settings picker.
- Intensify: one identity across window and floating surfaces; semantic colour restricted to
  small carriers.
- Add: a settings sidebar, an AI-provider credentials registry with per-feature assignments,
  a Library section for the four collections that live in modal sheets, and a sidebar entry
  for Insights (which currently has none).
- Explore: three navigation models — A Continuum (one window, nested settings), B Workbench
  (content window + native preferences window), C Modes (per-context profile as the primary
  object).
- Rule established: HUD glass belongs to floating panels only. In-window surfaces are opaque
  at the same hex values; there is nothing behind an opaque window to blur.
- Resulting node: `spark-app-system-01` (proposal; awaiting selection on D1–D5).
