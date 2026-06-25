# pi-app UX plan — 2026-06-25

## Scope

Plan for the next ApplePi/pi-app UX fixes after the new-session sidebar work.

## P0 — current behavior bugs

### 1. Streaming assistant bubble stability
- Keep one assistant streaming bubble visible from the moment the user sends a message until the turn fully ends.
- Do not let the bouncing-dots / streaming bubble disappear and reappear during thinking/tool calls.
- Stream content into the same visible assistant area instead of visually resetting it.

### 2. Live thinking / tool-call streaming visibility
- Show thinking blocks and tool calls in real time as they are emitted.
- Do not wait until the end of the turn and then dump the whole list at once.
- The chat should visibly grow step by step while the assistant is thinking and calling tools.

### 3. Auto-scroll behavior
- If the user is at the bottom of the chat, keep auto-scrolling on new assistant text, thinking, and tool events.
- If the user scrolls up, never yank them back down on streaming updates.
- Add a reliable "am I near bottom" tracker instead of always assuming anchored-to-bottom.

### 4. Composer text overflow
- Fix the composer text layout so long text never renders past the right edge.
- Recheck text container insets, wrapping, intrinsic width, and scroll behavior.

### 5. Taller composer
- Increase composer max height from roughly 8 lines to about 20 lines.
- Keep compact default height, only expand as content grows.

### 6. Send button -> Stop button while assistant is responding
- If the draft is empty and the session is currently sending, replace the send icon with a stop icon.
- Stop should abort the in-flight task/stream immediately.
- No text label, icon only.

### 7. Composer editing while streaming
- Make editing in the message field smooth while assistant output is streaming.
- Scrolling and cursor movement inside the composer must not fight with chat updates.
- Chat auto-scroll logic must not interfere with composer focus/scroll.

### 8. Steer message during response
- While the assistant is responding, if the user has typed text in the composer, the send button should stay enabled.
- This should allow a new steer message during the active run, similar to Telegram behavior.
- Need to confirm the exact backend interruption/continue semantics for pi-app remote flow.

### 9. Recent transcript cache while switching sessions
- Keep recent chat content cached when jumping between sessions.
- Target: at least the last ~40 recently used session tabs stay hot in memory.
- Switching back to a recently opened session should feel instant instead of waiting for a fresh reload every time.

## P1 — subagent UX

### Right sidebar for subagents
- Add a top-right button that opens a right sidebar/drawer.
- This sidebar shows subagents for the current session, newest/recent first.
- When new subagents start, auto-open the sidebar.

### Subagent list behavior
- Show each subagent as a clickable item.
- Main chat shows inline status rows like `{Subagent name} subagent running...`.
- Clicking the inline row opens that subagent in the right sidebar/detail view.
- Must support parallel subagents, not only one-at-a-time.

### Subagent detail view
- Read-only transcript.
- Show:
  - prompt sent to the subagent
  - model
  - thinking level
  - context usage
  - input/output token counts
  - streamed reasoning/actions/output as available in this client flow
- No composer/input field in subagent detail.

## P2 — layout simplification

### Remove left directory browser UI
- Remove/hide the directory menu/browser from the left side.
- Left side should stay focused on sessions only.
- Right side becomes the subagent area.

## Implementation order

### Phase 1 — chat stability and scrolling
1. Stable streaming assistant bubble
2. Live thinking / tool-call streaming visibility
3. Correct bottom-anchor detection and non-jumping scroll
4. Composer overflow fix
5. Composer max height increase

### Phase 2 — active-run controls
6. Stop button state
7. Smooth composer editing while streaming
8. Steer-message support during active response
9. Recent transcript cache while switching sessions

### Phase 3 — subagents and layout
10. Session-scoped subagent model/store
11. Right sidebar shell + open/close behavior
12. Inline "subagent running" rows in main chat
13. Subagent detail read-only transcript
14. Remove directory browser UI

## Notes / technical hints

### Streaming bubble
- Revisit `ChatSession` transient event handling.
- Thinking/tool updates should not temporarily remove the assistant placeholder.
- Prefer one stable in-flight assistant presentation over swapping between placeholder and persisted rows.

### Live thinking / tools
- Need incremental rendering for thinking/tool events, not post-turn replay only.
- Inspect current stream parsing and whether tool/thinking data is only persisted to jsonl and shown after reload.
- Prefer appending visible rows immediately from the live stream path.

### Scroll behavior
- `MessageListView` currently behaves as if it is always anchored to bottom.
- Need real scroll-position tracking and a threshold-based `isNearBottom` check.
- Streaming should only call `scrollToBottom` when near bottom.

### Stop / steer behavior
- Need to inspect current `sendTask` / cancel path and how pi-appd handles interruption.
- For steer messages during active send, decide whether:
  - current run is interrupted and replaced, or
  - steer is appended as another user message while stream is active.
- Mirror Telegram behavior as closely as practical.

### Recent transcript cache
- Current session switching should prefer hot in-memory tabs over forced reload.
- Keep an LRU-style cap so memory does not grow forever.
- If a hot session is selected again, show cached transcript immediately and refresh lazily only when needed.

### Subagents
- Need to inspect how subagent output is represented in current Pi stream/session model and what must be added to pi-appd/client parsing.
- Parallel subagents must be grouped per parent session with their own detail transcripts.

## Acceptance criteria

- Streaming assistant area no longer flickers/disappears during one turn.
- Thinking and tool-call rows appear live during the turn, not only after completion.
- Scrolling up in chat is respected during streaming.
- Composer text always wraps correctly.
- Composer can grow to ~20 lines.
- Empty composer + active run => stop icon.
- Non-empty composer + active run => send remains available for steer.
- Jumping back to a recently opened session feels instant from cache.
- Right sidebar shows subagents for current session and opens automatically when they start.
- Directory browser UI is gone from the main layout.
