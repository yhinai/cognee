# Clippy Enhancement Plan V2
### Synthesized from 3-Agent Analysis: Features Innovator, Tech Architect, Devil's Advocate

> **Context:** The P0 improvements (Keychain, SensitiveContentDetector, QueryOrchestrator, StatusBarMenu, SettingsView, crash resilience, dead code cleanup) are DONE. This plan covers everything that remains, with priorities recalibrated by the devil's advocate.
>
> **Key insight from devil's advocate:** Several P0 "done" items have quality issues that need fixing before any new features. The priority ordering from the original plan was wrong in several places.

---

## Phase 0: Fix What's Broken (Urgent - Before Any New Features)

> The devil's advocate found that several "done" items are incomplete or buggy. These must be fixed first.

### 0.1 Remove ALL `print()` Statements (Privacy Violation)

**Status:** Claimed DONE in Phase 1 -- actually NOT done. 80+ print statements remain across the codebase logging user data.

| File | Line Count | Logging User Data? |
|------|-----------|-------------------|
| VectorSearchService.swift | 12 statements | Yes (search queries) |
| GeminiService.swift | 18 statements | Yes (API responses, questions) |
| ClipboardMonitor.swift | 11 statements | Yes (clipboard content) |
| QueryOrchestrator.swift | 2 statements | Yes (query details) |
| AppDependencyContainer.swift | 4 statements | No (operational) |
| ContentView.swift | 6 statements | Yes (responses) |

**Fix:** Replace ALL with `os_log` using `.private` sensitivity:
```swift
import os
extension Logger {
    static let clipboard = Logger(subsystem: "com.clippy.app", category: "clipboard")
    static let ai = Logger(subsystem: "com.clippy.app", category: "ai")
    static let vector = Logger(subsystem: "com.clippy.app", category: "vector")
}
// Usage: Logger.clipboard.info("Saved item: \(title, privacy: .private)")
```

**Effort:** 1-2 days | **Impact:** Critical (privacy violation)

---

### 0.2 Fix StatusBarMenu `@Query` Missing `fetchLimit`

**Problem:** StatusBarMenu loads ALL items via `@Query` then slices with `.prefix(10)`. For users with thousands of items, this loads the entire dataset into memory for 10 rows.

**Fix:** Add `fetchLimit: 10` to the `@Query` declaration.

**Effort:** 5 minutes | **Impact:** High (memory)

---

### 0.3 Fix VisionScreenParser Semaphore Deadlock

**Problem:** `VisionScreenParser.swift:127` uses `DispatchSemaphore` to bridge async/sync. This WILL deadlock when the cooperative thread pool is exhausted.

**Fix:** Convert to async/await with `withCheckedThrowingContinuation` for Vision framework callbacks.

**Effort:** 4-6 hours | **Impact:** Critical (crash)

---

### 0.4 Fix QueryOrchestrator Error Leaking Across AI Services

**Problem:** `QueryOrchestrator.swift:120` reads `geminiService.lastErrorMessage` regardless of which AI service was used. Stale Gemini errors leak when using local AI.

**Fix:** Only read error from the service that was actually used.

**Effort:** 30 minutes | **Impact:** Medium (wrong error messages)

---

### 0.5 Cache `isSensitive` Computed Property

**Problem:** `Item.isSensitive` (Models.swift) runs 5 detection functions with ~15 regex patterns on every SwiftUI render. With 500+ items, this is O(n * p) regex evaluations per render cycle.

**Fix:** Cache the result as a stored property, computed once on save/load.

**Effort:** 1-2 hours | **Impact:** High (performance)

---

### 0.6 Add Image File Cleanup on Deletion

**Problem:** Deleting items removes SwiftData records but NOT image files on disk. `~/Library/Application Support/Clippy/Images/` grows unbounded.

**Fix:** Add `FileManager.removeItem` for image path in `ClipboardRepository.deleteItem()`.

**Effort:** 1 hour | **Impact:** Medium (disk leak)

---

### 0.7 Fix `deleteDocument` Not Removing from Pending Queue

**Problem:** `VectorSearchService.deleteDocument()` doesn't remove from `pendingVectorItems`. Items queued before DB init get re-indexed after deletion.

**Fix:** Filter `pendingVectorItems` in `deleteDocument()`.

**Effort:** 15 minutes | **Impact:** Low (data integrity edge case)

---

## Phase 1: Critical Quality & Safety (Week 1-2)

### 1.1 Undo Support for AI Text Replacement

**Priority:** P0 (was P2 -- devil's advocate promoted this)

**Problem:** Option+X replaces typed text with AI answer by sending backspace events. If AI gives a wrong answer, the original text is permanently lost. This is a data-loss bug.

**Solution:** Store `capturedText` content (not just length) in TextCaptureService. On Cmd+Z within 30 seconds of replacement: delete the pasted answer, re-type original text. Show toast: "AI answer inserted. Cmd+Z to undo."

**Effort:** 2-3 days | **Risk:** Medium (CGEvent fragility)

---

### 1.2 Gemini API Rate Limiting

**Problem:** Every clipboard item triggers `generateTags()`. Bulk paste fires 50+ API calls with no debouncing, no queue, no retry with backoff. Hitting 429 kills ALL queries.

**Solution:** Add a request queue with:
- Max 5 concurrent requests
- Exponential backoff on 429
- Debounce tag generation by 2 seconds
- Priority queue (user queries > auto-tagging)

**Effort:** 1-2 days | **Risk:** Low

---

### 1.3 Versioned Schema Migration (Replace Destructive Recovery)

**Problem:** Current migration deletes the entire database on schema change. Users lose all history on app updates.

**Solution:** Implement SwiftData `VersionedSchema` + `SchemaMigrationPlan` with lightweight migrations.

**Effort:** 4-6 hours | **Risk:** Medium (SwiftData migration APIs have rough edges)

---

### 1.4 Test Infrastructure + Initial Suite

**Priority:** P0 (was P1 -- devil's advocate promoted this)

**Problem:** Zero tests. Every "fix" from Phase 1 is unverified.

**Solution:**
1. Create `ClippyTests` target
2. Extract protocols for testability: `VectorSearchProtocol`, `ClipboardServiceProtocol`, `ContextEngineProtocol`
3. Remove singletons (`ClipboardService.shared`, `ActionDetector.shared`) -- move to DI container
4. Write initial 30-40 tests covering:
   - SensitiveContentDetector (all patterns, false positive rates)
   - ActionDetector (all detection types)
   - ClipboardRepository (CRUD, dedup, delete)
   - QueryOrchestrator (RAG pipeline with mocks)
   - GeminiService response parsing

**Effort:** 3-4 days | **Risk:** Low (additive)

---

## Phase 2: Quick Wins (2-3 Days)

> High-impact, low-effort features that already have infrastructure in place.

### 2.1 Render ActionDetector Results in UI

**Problem:** ActionDetector computes actions (Open URL, Call, Email, Maps, Calendar) for every row but NEVER displays them. Zero user value for non-zero compute cost.

**Fix:** Add an HStack of small action buttons below tags in ClipboardItemRow. `ClipboardAction.perform()` already handles all action types.

**Effort:** 0.5 days | **Impact:** Exceptional ROI

---

### 2.2 Model Download Progress Indicator

**Problem:** First launch shows no feedback during 10-30s model download. Users think the app is broken.

**Fix:** `LocalAIService.loadingProgress` and `statusMessage` already exist as `@Published` properties. Just observe them in SidebarView or ContentView with a progress banner.

**Effort:** 0.5 days | **Impact:** Exceptional ROI

---

### 2.3 Copy Feedback in ClipboardListView

**Problem:** StatusBarMenu and DetailView have copy feedback, but ClipboardListView (the primary view) has NONE.

**Fix:** Add `copiedItemId` state + checkmark overlay (same pattern as StatusBarMenu).

**Effort:** 0.5 days | **Impact:** High

---

### 2.4 AI Text Transforms via Gemini

**Problem:** Context menu transforms (Fix Grammar, Summarize, To JSON) only use local 1.5B model. Gemini would give much better results.

**Fix:** Add `transformText` to GeminiService, route through `selectedAIServiceType`.

**Effort:** 0.5 days | **Impact:** Medium

---

### 2.5 Auto-Summarize Long Clips (Smart Titles)

**Problem:** `item.title` is only set for images. Long text clips show truncated content in the list, making them hard to identify.

**Fix:** Add title generation alongside tag generation in `ClipboardMonitor.enhanceItem()`. Modify the AI prompt to return both tags and a one-line title.

**Effort:** 1 day | **Impact:** High (dramatically improves list browsability)

---

## Phase 3: Core UX Enhancements (1-2 Weeks)

### 3.1 Spotlight-like Global Search Overlay

**Description:** Global hotkey (Cmd+Shift+V) summons a floating search bar anywhere on screen. Type to search clipboard history (semantic + text), Enter pastes the selected item. This is the #1 feature that Raycast/Alfred clipboard managers have that Clippy doesn't.

**Effort:** 4-5 days | **Impact:** Very High (THE differentiator for power users)

---

### 3.2 Keyboard-First Navigation

Full keyboard control in the main window:
- Arrow Up/Down to browse items
- Enter to copy selected item
- Cmd+1-9 for quick copy by position
- Cmd+F to focus search
- Cmd+Delete to delete
- Space to toggle favorite

**Effort:** 2-3 days | **Impact:** High

---

### 3.3 Clipboard Expiry / Self-Destructing Clips

Add `expiresAt: Date?` to Item model. Configurable TTL (1h, 24h, 7d, 30d, never). Sensitive items default to 1h. Favorites exempt.

**Effort:** 1-2 days | **Impact:** High (privacy + clutter control)

---

### 3.4 Conversational AI with Memory

Add conversation history to QueryOrchestrator. Users can ask follow-up questions via Option+X without repeating context. Clear after 30 minutes of inactivity.

**Effort:** 1-2 days | **Impact:** High

---

### 3.5 Drag-and-Drop from Clipboard History

Add `.draggable()` modifier to ClipboardItemRow. Text drags as text, images as images. Works in ClipboardListView.

**Effort:** 1-2 days | **Impact:** Medium

---

### 3.6 Merge Clips

Select 2+ items -> right-click -> "Merge" with separator options (newline, comma, space) or AI-merge.

**Effort:** 1 day | **Impact:** Medium

---

## Phase 4: Multi-Model AI Strategy (1-2 Weeks)

### 4.1 Unified Streaming Protocol

Add `generateAnswerStream()` to `AIServiceProtocol` with a default implementation that collects the stream. Simplifies QueryOrchestrator to one code path.

**Effort:** 4-6 hours | **Impact:** Medium (architectural foundation)

---

### 4.2 Claude API Integration

Add `ClaudeService` implementing `AIServiceProtocol`. Uses Messages API. Extend `AIServiceType` with `.claude` case.

**Effort:** 4-6 hours | **Impact:** High

---

### 4.3 OpenAI API Integration

Add `OpenAIService` implementing `AIServiceProtocol`. Chat Completions API.

**Effort:** 4-6 hours | **Impact:** High

---

### 4.4 Ollama Local Model Support

Add `OllamaService` that connects to `localhost:11434`. Auto-detect Ollama availability. Let users pick which model to use. Zero-download local AI for Ollama users.

**Effort:** 4-6 hours | **Impact:** Medium

---

### 4.5 Token Usage Tracking

Track API usage per service. Show estimated cost in Settings. Help users avoid surprise API bills.

**Effort:** 4-6 hours | **Impact:** Medium

---

## Phase 5: Developer Features (2-3 Weeks)

### 5.1 Quick Developer Transforms

Context menu submenu with:
- Base64 Encode/Decode
- URL Encode/Decode
- JSON Escape/Unescape, Format/Minify
- camelCase / snake_case / kebab-case
- Hash (MD5, SHA256)
- Timestamp <-> human date
- Sort/dedup lines
- Extract all URLs/emails/IPs

All pure Swift string operations — no AI needed.

**Effort:** 2-3 days | **Impact:** Medium

---

### 5.2 JSON/XML/YAML Formatter

Auto-detect structured data. Show "Format" / "Minify" buttons in detail view. Pretty-print with proper indentation.

**Effort:** 1-2 days | **Impact:** Medium

---

### 5.3 Diff View (Compare Two Clips)

Select two items -> "Compare" -> side-by-side diff view with colored additions/deletions.

**Effort:** 3-4 days | **Impact:** Medium

---

### 5.4 URL Scheme Handler

Register `clippy://` scheme:
- `clippy://search?q=email`
- `clippy://copy?text=Hello`
- `clippy://ask?q=question`

Enables automation from Alfred, Raycast, shell scripts.

**Effort:** 1-2 days | **Impact:** Medium

---

## Phase 6: Polish & Accessibility (2-3 Weeks)

### 6.1 Interactive Onboarding Flow

4-5 screens: Welcome -> Accessibility permission -> Screen Recording -> AI setup -> Feature tour. "Setup incomplete" badge if permissions missing.

**Effort:** 3-4 days | **Impact:** High

---

### 6.2 Full VoiceOver Support

Accessibility audit of all views. Add `.accessibilityLabel()`, `.accessibilityHint()`, `.accessibilityAction()` to all interactive elements.

**Effort:** 2-3 days | **Impact:** High (accessibility compliance)

---

### 6.3 Shortcuts App Integration (App Intents)

Expose actions: "Get Latest Clipboard", "Search History", "Ask Clippy", "Copy Text". Enables Shortcuts automations.

**Effort:** 3-4 days | **Impact:** Medium

---

### 6.4 Data Export/Import

JSON export/import via SettingsView. `.clippybackup` format. Enables backup/restore and migration from competitors.

**Effort:** 4-6 hours | **Impact:** Medium

---

### 6.5 Diagnostic Export for Bug Reports

"Copy Diagnostics" button in Settings. Includes: version, macOS version, item count, model status, memory usage, permissions, last error. No user content.

**Effort:** 2-3 hours | **Impact:** Medium

---

## CUT LIST (Devil's Advocate Recommendations)

These items from the original plan should NOT be implemented:

| Item | Reason to Cut |
|------|--------------|
| Folders/Collections | Feature creep. Tags already cover this. Adds complexity for marginal value. |
| Snippets/Templates | Different product (TextExpander). Not a clipboard manager's job. |
| iCloud Sync | Effort: Large. Unsandboxed app with no test suite -- reckless to attempt. |
| InputModeStateMachine extraction | Over-engineering. 3 states with trivial transitions. ContentView at 500 lines is already reasonable. |
| Replace Vector DB with FTS5 | Guts the product's differentiator. Semantic search IS the value prop. |
| Replace local LLM with regex heuristics | Defeats the "AI-powered" positioning. ActionDetector already does heuristic detection. |
| AppleScript Dictionary | Effort: Large. URL schemes cover 90% of automation use cases for 20% of the work. |
| Smart Workflow Detection | 7+ days effort, very hard to avoid false positives. Not worth it yet. |

---

## Priority Summary

```
Phase 0 — Fix Broken Things (3-4 days)
├── os_log migration (80+ print statements)
├── StatusBarMenu fetchLimit
├── VisionScreenParser deadlock
├── QueryOrchestrator error leak
├── Cache isSensitive
├── Image file cleanup
└── Pending queue fix

Phase 1 — Critical Quality (1-2 weeks)
├── Undo for AI text replacement
├── Gemini API rate limiting
├── Versioned schema migration
└── Test infrastructure + 30-40 tests

Phase 2 — Quick Wins (2-3 days)
├── Render ActionDetector results
├── Model download progress
├── Copy feedback in list view
├── AI transforms via Gemini
└── Auto-summarize (smart titles)

Phase 3 — Core UX (1-2 weeks)
├── Spotlight-like search overlay
├── Keyboard-first navigation
├── Clipboard expiry
├── Conversational AI memory
├── Drag-and-drop
└── Merge clips

Phase 4 — Multi-Model AI (1-2 weeks)
├── Unified streaming protocol
├── Claude API integration
├── OpenAI API integration
├── Ollama support
└── Token usage tracking

Phase 5 — Developer Features (2-3 weeks)
├── Quick developer transforms
├── JSON/XML formatter
├── Diff view
└── URL scheme handler

Phase 6 — Polish (2-3 weeks)
├── Onboarding flow
├── VoiceOver support
├── Shortcuts integration
├── Data export/import
└── Diagnostic export
```

---

## Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Test coverage | 0% | >60% core services |
| Memory (idle, no models) | ~2GB | <200MB |
| print() statements logging user data | 80+ | 0 |
| Force unwraps | 0 (fixed) | 0 |
| Plaintext secrets | 0 (fixed) | 0 |
| Status menu open latency | Loads all items | <100ms (fetchLimit) |
| AI services supported | 2 (Gemini, Local) | 5 (+ Claude, OpenAI, Ollama) |
| Keyboard shortcuts in main window | 0 | Full navigation |

---

*Synthesized from three independent analyses: Features & UX Innovator (28 proposals), Technical Architect (29 proposals), Devil's Advocate (critical review of implementations + priority recalibration). 2026-02-07.*
