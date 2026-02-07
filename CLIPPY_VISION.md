# Clippy Vision: The Definitive Roadmap

### Synthesized from 6-Agent Analysis (Two Rounds)
### UX Visionary + Technical Architect + Reality Checker

> **Status:** Phase 0 (fix broken things) is DONE. All 7 items implemented and verified.
> This plan covers everything from here forward.

---

## The One-Sentence Vision

**The clipboard manager with search so good it feels like magic -- running entirely on Apple Silicon, no cloud, no API keys, no setup.**

---

## What Three Perspectives Agreed On

All three agents -- UX, Architecture, and Devil's Advocate -- converged on the same top 5 priorities:

| # | Feature | Why All Three Agree |
|---|---------|-------------------|
| 1 | **Global Search Overlay (Cmd+Shift+V)** | UX: "THE most important missing feature." Tech: "The single most impactful UX feature." Reality: "Ship this or the product is dead on arrival." |
| 2 | **Lazy Model Loading** | UX: implied (instant access pillar). Tech: "Idle memory <200MB." Reality: "If you can't get idle memory under 200MB, you lose every power user." |
| 3 | **Schema Migration Fix** | UX: trust pillar. Tech: "VersionedSchema with lightweight migration." Reality: "Users will not forgive lost data." |
| 4 | **Keyboard-First Navigation** | UX: table stakes for power users. Tech: keyboard shortcuts in main window. Reality: "Values keyboard shortcuts over mouse interactions." |
| 5 | **Test Suite** | UX: quality foundation. Tech: "Protocol-based services unlock testing." Reality: "Zero tests. Every fix is unverified." |

---

## Target User

**The Developer Who Copies 50+ Things Per Day**

- Copies code snippets, URLs, terminal output, API keys, JSON payloads, error messages
- Frequently needs to find something copied hours ago
- Lives in the terminal and editor, hates switching windows
- Cares about privacy (local-first, no cloud dependency)
- Will tolerate higher resource usage if search is genuinely magical
- Values keyboard shortcuts over mouse interactions

---

## What to Build (Prioritized)

### Phase 1: The Product (2-3 Weeks)
*Ship the features that justify Clippy's existence*

#### 1.1 Global Search Overlay (Cmd+Shift+V) -- THE Feature
**All three agents ranked this #1. This IS the product.**

```
User presses Cmd+Shift+V anywhere on macOS:

+========================================+
|  [magnifying glass] Search clipboard   |
+========================================+
|                                        |
|  [1] nihal@example.com                 |
|      Email - Safari - 2m ago           |
|                                        |
|  [2] SELECT * FROM users WHERE...      |
|      SQL - Terminal - 15m ago          |
|                                        |
|  [3] https://github.com/user/repo     |
|      URL - Chrome - 1h ago   [Open ->] |
|                                        |
+========================================+
| Enter: Paste  Tab: Preview  Esc: Close |
+========================================+
```

**Key design decisions:**
- NSPanel with `.floating` level, `.nonactivatingPanel` (doesn't steal focus from source app)
- Shows 5-7 items, each with: content preview, source app, relative time, tags, detected actions
- Search is hybrid: text filter results appear instantly (<50ms), semantic results stream in after
- Sensitive items show masked content with lock icon
- Images show 32x32 thumbnail inline
- Keyboard shortcut hints at the bottom

**Technical implementation:**
- New `SearchOverlayController` with `NSPanel`
- Reuses existing search infrastructure (`VectorSearchService.search()`, SwiftData queries)
- Registered via `HotkeyManager` (existing infrastructure)
- Enter pastes using existing `skipNextClipboardChange` pattern
- Esc dismisses

**Effort:** 4-5 days | **Impact:** Transformative

---

#### 1.2 Lazy Model Loading + Memory Budget
**Get idle memory from ~2GB to <200MB**

| Component | Current | Target | Strategy |
|-----------|---------|--------|----------|
| MLX Model (Qwen2.5-1.5B) | ~1.5GB always loaded | 0 until first AI query | Lazy load, unload after 5min idle |
| Vector DB (Qwen3-Embedding) | ~300MB always loaded | 0 until first search | Lazy init on first search |
| SwiftData items | Unbounded | Paginated | `fetchLimit` on all queries |

```swift
actor ModelLifecycle {
    enum State {
        case unloaded
        case loading(Task<ModelContainer, Error>)
        case loaded(ModelContainer, lastUsed: Date)
    }

    private var state: State = .unloaded
    private let idleTimeout: TimeInterval = 300 // 5 minutes

    func getModel() async throws -> ModelContainer {
        switch state {
        case .unloaded:
            let task = Task { try await loadModel() }
            state = .loading(task)
            let container = try await task.value
            state = .loaded(container, lastUsed: Date())
            return container
        case .loading(let task):
            return try await task.value
        case .loaded(let container, _):
            state = .loaded(container, lastUsed: Date())
            return container
        }
    }

    func checkIdleUnload() {
        guard case .loaded(_, let lastUsed) = state else { return }
        if Date().timeIntervalSince(lastUsed) > idleTimeout {
            state = .unloaded // Frees ~1.5GB
        }
    }
}
```

**Effort:** 2-3 days | **Impact:** Critical (250x memory reduction when idle)

---

#### 1.3 Keyboard-First Navigation
**Every interaction reachable by keyboard**

Main Window:
| Shortcut | Action |
|----------|--------|
| Up/Down | Navigate items in list |
| Enter | Copy selected item to clipboard |
| Space | Toggle preview/detail panel |
| Cmd+F | Focus search field |
| Cmd+1-9 | Quick-copy item by position |
| Cmd+Delete | Delete selected item |
| Cmd+D | Toggle favorite |
| Escape | Clear selection / dismiss search |
| Tab | Cycle focus: sidebar -> list -> detail |

Command Bar:
| Shortcut | Action |
|----------|--------|
| Up/Down | Navigate items |
| Enter | Paste selected item |
| Cmd+Enter | Copy without pasting |
| Option+Enter | Show full preview |
| Cmd+1-9 | Paste item by position |

**Effort:** 2-3 days | **Impact:** High

---

#### 1.4 Versioned Schema Migration
**Stop deleting user data on app updates**

```swift
enum ClippySchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] = [ItemV1.self]
}

enum ClippySchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [ItemV2.self]
    // Adds: isSensitiveFlag, expiresAt, sourceURL
}

enum ClippyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        ClippySchemaV1.self, ClippySchemaV2.self
    ]
    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: ClippySchemaV1.self, toVersion: ClippySchemaV2.self)
    ]
}
```

**Effort:** 4-6 hours | **Impact:** Critical (data safety)

---

#### 1.5 Undo for AI Text Replacement (Option+X Safety Net)

**Problem:** Option+X replaces user text with AI answer irreversibly. One hallucination and the user's work is destroyed.

**Solution:** Store `capturedText` content before replacement. On Cmd+Z within 30 seconds: delete AI answer, re-type original text. Show toast: "AI answer inserted. Cmd+Z to undo."

**Effort:** 2-3 days | **Impact:** Critical (data safety)

---

### Phase 2: Quick Wins (3-5 Days)
*High ROI changes using existing infrastructure*

#### 2.1 Surface ActionDetector Results in UI
ActionDetector already computes actions (Open URL, Call, Email, Maps, Calendar) for every item -- but never displays them. Add small pill buttons below tags in ClipboardItemRow.

**Effort:** 0.5 days | **Impact:** Exceptional ROI

#### 2.2 Model Download Progress Indicator
`LocalAIService.loadingProgress` already exists as `@Published`. Just observe it with a progress banner in the sidebar.

**Effort:** 0.5 days | **Impact:** Exceptional ROI

#### 2.3 Copy Feedback in ClipboardListView
Reuse the `copiedItemId` + green checkmark pattern from StatusBarMenu.

**Effort:** 2 hours | **Impact:** High

#### 2.4 Auto-Summarize Long Clips (Smart Titles)
Generate one-line titles alongside tags in `ClipboardMonitor.enhanceItem()`. Makes the list dramatically more browsable.

**Effort:** 1 day | **Impact:** High

#### 2.5 AI Service Picker -> Settings
Move the "Gemini vs Local AI" picker from the sidebar to Settings. Default to local AI. Users don't care which model generates their tags -- they care that search works.

**Effort:** 2 hours | **Impact:** Medium (reduces UI clutter)

---

### Phase 3: Reliability & Testing (1-2 Weeks)
*Build the foundation for everything else*

#### 3.1 Protocol-Based Service Architecture
Extract protocols for all services to enable testing and future extensibility.

```swift
protocol VectorSearching: Actor {
    func addDocument(id: UUID, text: String) async
    func search(query: String, limit: Int) async -> [(UUID, Float)]
    func deleteDocument(id: UUID) async throws
}

protocol ClipboardMonitoring: AnyObject, ObservableObject {
    var clipboardContent: String { get }
    func startMonitoring()
    func stopMonitoring()
}

protocol ContextProviding: Actor {
    func currentContext() async -> AppContext
    func richContext(clipboardContent: String) async -> String
}
```

**Effort:** 2-3 days | **Impact:** High (unlocks testing)

#### 3.2 Test Infrastructure + Initial Suite (40+ Tests)
1. Create `ClippyTests` target
2. Remove singletons (`ClipboardService.shared`, `ActionDetector.shared`) -- move to DI container
3. Write tests covering:
   - SensitiveContentDetector (95% -- security-critical)
   - ActionDetector (90%)
   - AI response parsing (95%)
   - ClipboardRepository CRUD (85%)
   - QueryOrchestrator pipeline with mocks (80%)

**Effort:** 3-4 days | **Impact:** Critical

#### 3.3 Gemini API Rate Limiting
Add request queue: max 5 concurrent, exponential backoff on 429, debounce tag generation by 2 seconds, priority queue (user queries > auto-tagging).

**Effort:** 1-2 days | **Impact:** High

#### 3.4 Clipboard Expiry / Self-Destructing Clips
Add `expiresAt: Date?` to Item model. Sensitive items default to 1h auto-expire. Favorites exempt.

**Effort:** 1-2 days | **Impact:** High (privacy)

---

### Phase 4: Performance & Architecture (1-2 Weeks)
*Make Clippy fast and maintainable*

#### 4.1 Actor-Based Concurrency
Move `VectorSearchService` and AI services off `@MainActor`. Only UI-bound state stays on main.

```swift
actor VectorSearchService: VectorSearching {
    private var vectorDB: VecturaMLXKit?
    private var pendingItems: [(UUID, String)] = []

    func search(query: String, limit: Int) async -> [(UUID, Float)] {
        guard let db = vectorDB else { return [] }
        let results = try? await db.search(query: query, numResults: limit, threshold: nil)
        return results?.map { ($0.id, $0.score) } ?? []
    }
}
```

**Effort:** 2-3 days | **Impact:** High (UI responsiveness)

#### 4.2 Search Performance Optimization
Pre-built UUID -> PersistentIdentifier lookup dictionary for O(1) vector result mapping (currently O(n) over all items).

**Effort:** 1 day | **Impact:** High for large histories

#### 4.3 Clipboard Polling Optimization
Exponential backoff: 0.3s during active copying, 2s when idle. Saves CPU.

**Effort:** 0.5 days | **Impact:** Medium

#### 4.4 Network Resilience
Token bucket rate limiter + circuit breaker for cloud AI providers. Prevents hammering failing APIs.

**Effort:** 1-2 days | **Impact:** Medium

---

### Phase 5: Multi-Model AI Platform (1-2 Weeks)
*Make AI provider support extensible*

#### 5.1 AI Provider Registry
Replace hardcoded Gemini/Local with a registry pattern. Adding a new provider = implement one protocol, register it.

```swift
protocol AIProvider: Actor, Identifiable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: Set<AICapability> { get }
    var isAvailable: Bool { get async }
    func generateAnswer(question: String, context: [RAGContextItem],
                        options: GenerationOptions) -> AsyncThrowingStream<String, Error>
    func generateTags(content: String) async throws -> [String]
}

actor AIRouter {
    // Tries preferred provider -> fallback -> local (always available)
    func route(query: String, ...) -> AsyncThrowingStream<String, Error>
}
```

#### 5.2 Unified Streaming Protocol
All providers return `AsyncThrowingStream<String, Error>`. Non-streaming APIs are wrapped.

#### 5.3 New Providers
- **Claude** (Anthropic Messages API)
- **OpenAI** (Chat Completions API)
- **Ollama** (localhost:11434, auto-detect availability)

#### 5.4 Token Usage Tracking
Track usage per provider, show estimated cost in Settings.

**Total Phase Effort:** 1-2 weeks | **Impact:** High (flexibility + portfolio showcase)

---

### Phase 6: Developer Power Features (1-2 Weeks)

#### 6.1 Developer Transforms (No AI Required)
Context menu with pure Swift string operations:
- Base64 Encode/Decode
- URL Encode/Decode
- JSON Format/Minify
- camelCase / snake_case / kebab-case
- SHA-256 Hash
- Timestamp <-> human date
- Sort/dedup lines
- Extract all URLs/emails/IPs

**Effort:** 2-3 days | **Impact:** Medium

#### 6.2 URL Scheme Handler
Register `clippy://` scheme for automation:
- `clippy://search?q=email`
- `clippy://copy?text=Hello`
- `clippy://ask?q=question`
- `clippy://latest`

**Effort:** 1-2 days | **Impact:** Medium

#### 6.3 Data Export/Import
JSON export/import via Settings. `.clippybackup` bundle format (metadata.json + images/).

**Effort:** 4-6 hours | **Impact:** Medium

#### 6.4 Diagnostic Export
"Copy Diagnostics" button in Settings. Version, macOS, item count, model status, memory usage, permissions, last error. No user content.

**Effort:** 2-3 hours | **Impact:** Medium

---

### Phase 7: Polish & Community (2-3 Weeks)

#### 7.1 Onboarding Flow (4 Steps, Under 60 Seconds)
1. Welcome (Clippy waving)
2. Permissions (Accessibility + Screen Recording with explanations)
3. Choose AI (Local recommended, Gemini optional)
4. Try It! (Interactive shortcut demo)

#### 7.2 Rich Content Previews
- Images: 48x48 thumbnails (async loaded)
- Code: Monospaced font + purple tint (heuristic detection)
- URLs: Domain with colored circle + "Open" action
- Sensitive: Masked content with lock icon + TTL countdown

#### 7.3 Smart Sidebar Categories
Auto-generated from top tags: Code, URLs, Emails, plus Recent Apps grouping.

#### 7.4 Settings Redesign
Tabbed macOS Settings window: General | AI | Privacy | Shortcuts | About

#### 7.5 Full VoiceOver Support
Accessibility audit of all views. Labels, hints, actions on all interactive elements.

#### 7.6 Drag-and-Drop
`.draggable()` on ClipboardItemRow. Text as text, images as images.

---

## What NOT to Build (Cut List)

All three perspectives agreed these should be cut or deferred indefinitely:

| Feature | Why Cut |
|---------|---------|
| **iCloud Sync** | No test suite + unsandboxed = recipe for data loss. Defer to v2.0 after 80%+ coverage. |
| **Folders/Collections** | Tags already cover this. Feature creep. |
| **Snippets/Templates** | That's TextExpander. Not a clipboard manager's job. |
| **Conversational AI Memory** | Reality check: "Users are not having conversations with their clipboard manager." |
| **Diff View** | Use a dedicated diff tool. Not a clipboard manager's job. |
| **Merge Clips** | "Feature that sounds useful but nobody will discover or use." |
| **AppleScript Dictionary** | URL schemes cover 90% of automation for 20% of the effort. |
| **Smart Workflow Detection** | 7+ days effort, very hard to avoid false positives. |
| **Replace Vector DB with FTS5** | Guts the product's differentiator. Semantic search IS the value prop. |

### Features to Reconsider

| Feature | Verdict |
|---------|---------|
| **ElevenLabs Voice Input** | Reality check says kill it (paid API, niche). UX says keep it. **Compromise: Keep code but remove from default UI. Power users can enable in Settings.** |
| **Option+X Text Replacement** | Reality check: "The scariest feature in the app." **Keep but add undo (Phase 1.5) before promoting it.** |
| **Shortcuts App Integration** | Reality check: "Polish for later." Tech: useful for automation. **Defer to Phase 7 but keep in plan.** |

---

## The Go-Viral Strategy

### Scenario A: "The AI Clipboard That Actually Works" (STRONGEST)
1. Ship the global search overlay with semantic search
2. Make it work with ZERO configuration (local embeddings only, no API key)
3. Record a 30-second demo: copy 20 things, press Cmd+Shift+V, type "that kubernetes config", instant result
4. Post to Hacker News: "I built a clipboard manager with semantic search that runs entirely on-device"
5. Positioning: privacy-first, Apple Silicon native, no cloud dependency

### Scenario B: "Clippy Is Back"
- The animated Clippy character is inherently shareable
- Make it the mascot of the search overlay
- Video of Clippy appearing, "thinking", surfacing the right clipboard item
- Post to Twitter/X with nostalgia angle

### Scenario C: "The Developer's Clipboard"
- Ship developer transforms (base64, JSON format, URL encode)
- Add syntax highlighting for code snippets
- Post to dev.to / Reddit r/programming
- "Maccy is fine, but this understands code"

---

## Open Source Strategy

**Recommendation from all three agents: Open source it.**

The code quality is strong enough to attract contributors. The vector search architecture is genuinely interesting. An active open-source clipboard manager with semantic search would get attention on Hacker News and GitHub. That attention is worth more than license fees.

### Repository Structure
```
clippy/
+-- Clippy/
|   +-- App/
|   +-- Models/
|   +-- Protocols/           # Service protocols for testability
|   +-- Services/
|   |   +-- AI/              # AI providers (each in own file)
|   |   +-- Clipboard/       # Monitor, Repository
|   |   +-- Search/          # Vector, Text search
|   |   +-- Context/         # Accessibility, Vision
|   |   +-- Network/         # Rate limiter, Circuit breaker
|   |   +-- Platform/        # URL scheme, App Intents
|   +-- UI/
|   |   +-- Main/            # ContentView, Sidebar, List, Detail
|   |   +-- Overlay/         # Search overlay
|   |   +-- StatusBar/       # Menu bar
|   |   +-- Settings/        # Settings views
|   |   +-- Clippy/          # Character animation
|   +-- Plugins/             # Built-in plugins (transforms)
+-- ClippyTests/             # Unit + Integration tests
+-- .github/
|   +-- workflows/ci.yml
|   +-- ISSUE_TEMPLATE/
+-- LICENSE (MIT)
```

### Distribution
- DMG + Homebrew Cask (not Mac App Store -- sandbox blocks accessibility features)
- Sparkle for in-app auto-update
- GitHub Actions CI/CD pipeline

---

## Success Metrics

| Metric | Current | 3-Month Target | 6-Month Target |
|--------|---------|---------------|----------------|
| Test coverage | 0% | 60% core services | 80% |
| Memory (idle, no model) | ~2GB | <200MB | <150MB |
| Memory (with model) | ~2GB | <500MB | <400MB |
| Semantic search latency | Unknown | <100ms | <50ms |
| AI response (first token) | Unknown | <2s cloud / <1s local | <1s / <500ms |
| AI providers supported | 2 | 5 | 5+ (plugin) |
| print() statements | ~~80+~~ 0 (DONE) | 0 | 0 |
| Keyboard shortcuts | 0 | Full navigation | Full navigation |
| Command Bar invoke -> visible | N/A | <200ms | <100ms |
| Crash rate | Unknown | <0.1% sessions | <0.01% |

---

## Implementation Timeline

```
Phase 1 -- The Product (Weeks 1-3) <<<< START HERE
|-- Global Search Overlay (Cmd+Shift+V)
|-- Lazy Model Loading (memory <200MB)
|-- Keyboard-First Navigation
|-- Schema Migration Fix
+-- Undo for Option+X

Phase 2 -- Quick Wins (Week 3-4)
|-- Surface ActionDetector results
|-- Model download progress
|-- Copy feedback in list view
|-- Smart titles for long clips
+-- Move AI picker to Settings

Phase 3 -- Reliability (Weeks 4-6)
|-- Protocol extraction for services
|-- Test suite (40+ tests)
|-- Rate limiting for Gemini API
+-- Clipboard expiry (TTL)

Phase 4 -- Performance (Weeks 6-8)
|-- Actor-based concurrency
|-- Search performance (O(1) lookup)
|-- Polling optimization
+-- Network resilience (circuit breaker)

Phase 5 -- Multi-Model AI (Weeks 8-10)
|-- AI Provider Registry
|-- Unified streaming
|-- Claude + OpenAI + Ollama providers
+-- Token usage tracking

Phase 6 -- Developer Features (Weeks 10-12)
|-- Developer transforms (base64, JSON, etc.)
|-- URL scheme handler (clippy://)
|-- Data export/import
+-- Diagnostic export

Phase 7 -- Polish & Community (Weeks 12-15)
|-- Onboarding flow
|-- Rich content previews
|-- Smart sidebar categories
|-- Settings redesign
|-- VoiceOver accessibility
+-- Drag-and-drop
```

---

## The Final Word

> "Users do not care about your architecture. They care about finding the thing they copied 3 hours ago, in under 2 seconds, from wherever they are on screen."
> -- Reality Checker

> "Clippy should feel like macOS muscle memory within 10 minutes of installation."
> -- UX Visionary

> "The most important technical constraint: never ship iCloud Sync without 80%+ test coverage."
> -- Technical Architect

**Ship the global search overlay. Make it fast. Make it work without configuration. Everything else follows.**

---

*Synthesized from 6 independent agent analyses across 2 rounds. February 2026.*
