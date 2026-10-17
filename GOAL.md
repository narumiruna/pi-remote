以下 Prompt 可以直接交給 Codex 或其他 Coding Agent。

目標是將 Pi Remote for Mac 改造成類似 Herdr 的 Workspace-first Coding Agent UI，同時保留原本的白色 SwiftUI 風格。

要求 Coding Agent 先檢查現有架構，再直接實作，不只提出設計方案。

# Implement Workspace-Based Session UI for Pi Remote for Mac

## Goal

Redesign the Pi Remote for Mac interface into a workspace-first coding agent application, inspired by Herdr's navigation model.

Users should be able to:

1. Add or select a workspace (a local Mac directory).
2. Expand a workspace to see its Pi sessions.
3. Select an existing session and view its conversation.
4. Send messages and interact with Pi directly from the Mac application.
5. Create a new Pi session in a selected workspace.
6. Switch between sessions without losing conversation history or interrupting running agents.
7. Monitor agent activity, tool calls, and connection status.

The application should feel like a native macOS coding agent, not a remote terminal or web dashboard.

**Important: Preserve the existing light appearance. Do not introduce a dark theme or a theme system.**

## 1. Inspect the Repository First

Before changing code, investigate:

- Existing SwiftUI views and navigation structure.
- Mac companion application architecture.
- Pi RPC integration and process lifecycle.
- Session creation, listing, loading, switching, and persistence.
- How session history and streaming events are represented.
- Workspace and working-directory management.
- Connection, listener, and device pairing state.
- Existing tests, reusable components, and design conventions.

Identify the current boundaries between presentation, application state, RPC transport, and persistence.

Reuse existing functionality wherever possible.

Do not replace working infrastructure solely to support the new UI.

After inspection, implement the redesign. Do not stop at a proposal.

## 2. Design Principles

### Preserve the existing visual identity

Use the current application's light appearance:

- White primary backgrounds.
- Subtle light-gray surfaces.
- Existing blue accent color.
- Native macOS typography.
- Thin separators and restrained borders.
- Minimal shadows.
- Standard SwiftUI controls wherever appropriate.

Avoid:

- Dark backgrounds or forced dark mode.
- Theme configuration or appearance switching.
- Glassmorphism.
- Gradients and neon effects.
- Excessive cards and nested containers.
- Decorative icons without meaningful functions.
- A complete visual rebrand.

Focus on information hierarchy, navigation, density, and usability.

### Prefer native macOS interaction patterns

Use SwiftUI navigation and layout components where appropriate.

The interface should support:

- Resizable sidebar and inspector.
- Keyboard navigation.
- Context menus.
- Keyboard shortcuts.
- Native file and folder selection.
- Persistent selection and appropriate window restoration.
- Native text selection and copying.

Do not reproduce a browser dashboard inside the Mac application.

## 3. Main Window Layout

Implement a workspace-oriented layout:

```
┌─────────────────────────────────────────────────────────────┐
│ Pi Remote                    Connected       New Session    │
├──────────────────┬──────────────────────────┬───────────────┤
│ WORKSPACES       │ Session / Status         │ INSPECTOR     │
│                  ├──────────────────────────┤               │
│ ▾ pi-extensions  │ Conversation             │ Session info  │
│   ● session A    │                          │               │
│   ○ session B    │ User message             │ Files         │
│                  │                          │               │
│ ▾ morsel         │ Pi response              │ Activity      │
│   ● session C    │                          │               │
│                  │ Tool calls               │               │
│ ▸ falcon         │                          │               │
│                  │                          │               │
│                  ├──────────────────────────┤               │
│ + Add Workspace  │ Message Pi...       Send │               │
└──────────────────┴──────────────────────────┴───────────────┘
```

Use three primary regions:

1. Workspace/session sidebar.
2. Main conversation area.
3. Optional inspector.

The conversation area must always receive the most horizontal space.

The inspector should be collapsible.

The layout must remain usable when the window is resized.

## 4. Workspace and Session Sidebar

Replace the existing Sessions modal and session-selection dropdown with persistent navigation.

### Workspace model

A workspace represents a local Mac directory used as a Pi working directory.

It is not necessarily a Git repository.

A workspace can contain multiple Pi sessions.

Show workspaces as expandable tree nodes:

```
WORKSPACES                      +

▾ pi-extensions
    ● lucky-stone-9674
    ○ silver-river-4213
    ○ narumi/feat/refactor

▾ morsel
    ● api-development
    ○ viewer-redesign

▸ changenote

▸ falcon

+ Add Workspace
```

Each workspace should support:

- Expand/collapse.
- Select workspace.
- Create session.
- Open folder in Finder.
- Remove from sidebar without deleting files.
- Show its associated sessions.

Each session should show:

- Session name or useful fallback identifier.
- Running, idle, completed, disconnected, or error status when supported by the actual state model.
- Last activity time when available.
- Selected state.

Use subtle indicators instead of large badges on every row.

### Workspace identity

Use normalized directory paths as workspace identifiers unless the existing architecture provides a more reliable identity.

Avoid grouping unrelated directories merely because they share the same final directory name.

Handle missing, renamed, and inaccessible directories gracefully.

### Session discovery

Reuse the existing Pi session discovery mechanism.

If sessions are associated with working directories, group them under the corresponding workspace.

Do not assume the currently running Pi process is the only available session.

Do not fabricate sessions from directory names.

Preserve the distinction between discovering an existing session and starting or resuming it.

### Sidebar context menus

Provide appropriate actions:

Workspace:

- New Session
- Open in Finder
- Copy Path
- Remove Workspace

Session:

- Open Session
- Rename, if supported
- Copy Session ID
- Fork, if supported
- Remove from list or delete, only when semantics are clearly defined

Destructive actions must be explicit and appropriately confirmed.

## 5. Session Conversation View

Selecting a session should display its Pi conversation in the main panel.

The experience should resemble a native coding agent interface, not a terminal emulator.

### Header

Display:

- Session name.
- Associated workspace.
- Pi execution status.
- Model and thinking level when available.
- Relevant session controls.

Keep the header compact.

Avoid displaying verbose filesystem paths as the main title.

### Conversation timeline

Render the conversation chronologically.

Support relevant Pi RPC event types, including:

- User messages.
- Assistant messages.
- Streaming assistant output.
- Tool calls.
- Tool results.
- Errors.
- System or lifecycle events.
- Interactive requests and responses.

Use the actual protocol data rather than interpreting terminal output as plain text.

### Assistant messages

Support:

- Markdown.
- Fenced code blocks.
- Syntax highlighting where available.
- Copying code and messages.
- Links.
- Incremental streaming updates.

Keep message content readable and selectable.

### Tool calls

Render tool calls as compact, expandable activity blocks.

Default presentation:

```
✓ Read file                         0.3s
  src/session/manager.swift

✓ Edit file                         0.5s
  src/session/manager.swift

◌ Run tests                         Running
  swift test
```

Expanding a tool call should reveal relevant inputs, outputs, errors, and execution details.

Do not dump large raw RPC payloads into the main conversation by default.

Preserve access to raw details when needed for debugging.

### Streaming behavior

- Append events incrementally.
- Preserve event ordering.
- Avoid duplicating events after reconnecting.
- Avoid expensive full-list rerenders for every token.
- Automatically scroll when the user is already near the bottom.
- Preserve scroll position when the user is reading older messages.
- Provide a clear way to jump back to the latest message.

Large session histories should remain responsive.

## 6. Message Composer

Place the message input at the bottom of the conversation area.

Requirements:

- Multiline text editing.
- Clear Send action.
- Appropriate keyboard shortcuts.
- Disabled or informative state when sending is impossible.
- Preserve unsent drafts when switching sessions.
- Display relevant model information without overwhelming the composer.
- Support existing Pi interaction capabilities without inventing unsupported features.

The composer must reflect the actual session state.

Do not display an enabled Send button when there is no usable Pi process or connection.

When the agent is running, distinguish between sending another message, steering, queuing, or interrupting according to existing Pi RPC semantics.

Do not treat these operations as interchangeable.

## 7. New Session Workflow

Creating a session should require minimal steps.

Expected flow:

1. Select a workspace.
2. Click New Session.
3. Start Pi in that workspace's directory.
4. Open the new session.
5. Begin typing instructions.

When no workspace is selected, allow the user to choose a local directory.

Provide recent workspaces when available.

Use the existing session creation APIs.

Do not create duplicate Pi processes accidentally.

Do not silently overwrite, reset, or fork an existing session.

## 8. Session Switching and Lifecycle

Session switching is a critical part of this redesign.

Users must be able to switch between sessions without accidentally terminating active work.

Separate these concepts:

- Selected UI session.
- Loaded Pi session.
- Running Pi process.
- Persisted session history.
- Network connection to the Mac companion.

Investigate whether the existing architecture supports multiple active Pi processes.

If it does, preserve their independent state.

If it does not, implement safe session activation and restoration using supported APIs.

Do not pretend multiple sessions are simultaneously running when only one process exists.

Switching sessions must not implicitly reset conversation context.

Do not implement session restoration by replaying previous messages as new user inputs.

## 9. Inspector Panel

Add an optional right-side inspector.

It should provide secondary information without competing with the conversation.

Recommended sections:

### Session

- Session name.
- Workspace.
- Working directory.
- Model.
- Thinking level.
- Session status.
- Token usage, when available.

### Files

- Browse files in the selected workspace.
- Expand directories.
- Copy relative paths.
- Open files in the default application or Finder.
- Respect existing directory access restrictions.

### Activity

- Recent tool calls.
- Current operation.
- Errors or warnings.

Do not duplicate the entire conversation history in the inspector.

Use progressive disclosure for secondary details.

The inspector must be collapsible and its visibility preference should persist.

## 10. Connection and Error States

The current UI mixes connection failures, listener state, and Pi availability.

Replace this with a consistent state model.

Distinguish:

- Mac listener/server unavailable.
- Remote device disconnected.
- Pi process not started.
- Pi process running.
- Pi process busy.
- Pi process exited or failed.
- Session history available but execution unavailable.

Display actionable recovery controls where supported.

For example:

```
Pi process unavailable

The saved conversation is available, but Pi is not running.

[Reconnect / Resume]
```

Only offer Resume if the existing implementation can actually perform it.

Avoid contradictory states such as showing both "unavailable" and "Ready for a task" without explanation.

Do not silently restart Pi when doing so might change user-visible session state.

## 11. Relocate Existing Mac Companion Settings

The current main view exposes administrative functionality directly in the workspace area.

Move secondary administration into an appropriate Settings or Devices interface.

Preserve:

- Start/stop listener.
- Device pairing.
- Device revocation.
- Pi executable configuration.
- Folder access permissions.
- Connection identity management.
- Network configuration.

Keep connection status visible in the main window, but do not display all configuration controls constantly.

Security-sensitive operations must retain existing confirmation and authorization requirements.

Do not modify existing pairing, TLS, or credential-handling semantics.

## 12. Persistence

Persist reasonable UI preferences:

- Added workspaces.
- Workspace expansion state.
- Selected workspace/session.
- Inspector visibility.
- Window/sidebar layout when appropriate.
- Unsent message drafts.

Use existing application storage conventions.

Do not persist provider credentials in new storage locations.

Do not duplicate sensitive session content unnecessarily.

## 13. Implementation Constraints

- Use Swift and SwiftUI.
- Respect existing Swift concurrency and actor-isolation conventions.
- Preserve Pi RPC compatibility.
- Preserve existing authentication and authorization behavior.
- Preserve session file compatibility.
- Preserve existing Mac/iPhone communication contracts.
- Avoid unnecessary dependencies.
- Do not add a web-based UI layer.
- Do not introduce themes or dark mode.
- Keep the implementation modular and maintainable.

The Mac interface may change substantially, but the existing iPhone client must continue working.

Avoid unrelated refactoring.

## 14. Testing

Add or update tests for:

- Workspace addition and removal.
- Workspace-to-session grouping.
- Session selection.
- Session creation.
- Session restoration.
- Switching between active sessions.
- Conversation history loading.
- Streaming event updates.
- Tool call rendering.
- Connection loss and recovery.
- Invalid or inaccessible workspace directories.
- Unsent message preservation.

Test lifecycle edge cases, especially session switching during an active agent run.

Run relevant build, test, and formatting commands.

Do not claim tests passed unless they were actually executed.

## 15. Acceptance Criteria

The implementation is complete when:

- The Mac app uses a workspace/session navigation sidebar.
- A workspace can contain multiple sessions.
- Selecting a session displays its saved conversation.
- The conversation supports Pi streaming events.
- Users can send messages directly from the Mac application.
- Users can start Pi in a selected directory.
- Switching sessions does not inadvertently terminate ongoing work.
- Tool calls and results are readable.
- The inspector can be shown or hidden.
- Connection and process statuses are consistent.
- Existing device management remains accessible.
- The original light appearance is preserved.
- No theme system or dark-mode redesign is introduced.
- The iPhone client and existing RPC compatibility remain intact.
- Relevant tests pass.

## 16. Execution Instructions

Implement the changes directly.

Work in this order:

1. Inspect the repository and identify existing reusable functionality.
2. Define the workspace/session UI state and lifecycle boundaries.
3. Implement the workspace sidebar.
4. Implement session selection and conversation rendering.
5. Implement message sending and session creation.
6. Implement the inspector and secondary navigation.
7. Relocate administrative controls.
8. Add tests and run validation.

If an existing RPC or persistence limitation prevents a feature, preserve correctness instead of simulating unsupported behavior.

At completion, report:

- Files changed.
- Architectural decisions.
- Implemented functionality.
- Tests executed and results.
- Remaining limitations.

Do not stop after producing mockups, architecture notes, or implementation suggestions.

Deliver working code.

### 額外建議：架構上的一個關鍵決定

我建議 Workspace 定義為資料夾，Session 定義為 Pi 的 session，而 Git branch/worktree 不直接成為必要的第三層。

例如：

\#chatgpt-mermaid-\_r_181\_{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;fill:rgb(13, 13, 13);}@keyframes edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}#chatgpt-mermaid-\_r_181\_ .edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_181\_ .edge-animation-fast{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_181\_ .error-icon{fill:rgb(243, 243, 243);}#chatgpt-mermaid-\_r_181\_ .error-text{fill:rgb(13, 13, 13);stroke:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ .edge-thickness-normal{stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .edge-thickness-thick{stroke-width:3.5px;}#chatgpt-mermaid-\_r_181\_ .edge-pattern-solid{stroke-dasharray:0;}#chatgpt-mermaid-\_r_181\_ .edge-thickness-invisible{stroke-width:0;fill:none;}#chatgpt-mermaid-\_r_181\_ .edge-pattern-dashed{stroke-dasharray:3;}#chatgpt-mermaid-\_r_181\_ .edge-pattern-dotted{stroke-dasharray:2;}#chatgpt-mermaid-\_r_181\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_181\_ .marker.cross{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_181\_ svg{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;}#chatgpt-mermaid-\_r_181\_ p{margin:0;}#chatgpt-mermaid-\_r_181\_ .label{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ .cluster-label text{fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ .cluster-label span{color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ .cluster-label span p{background-color:transparent;}#chatgpt-mermaid-\_r_181\_ .label text,#chatgpt-mermaid-\_r_181\_ span{fill:rgb(13, 13, 13);color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ .node rect,#chatgpt-mermaid-\_r_181\_ .node circle,#chatgpt-mermaid-\_r_181\_ .node ellipse,#chatgpt-mermaid-\_r_181\_ .node polygon,#chatgpt-mermaid-\_r_181\_ .node path{fill:rgb(222, 234, 251);stroke:rgb(83, 154, 248);stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .rough-node .label text,#chatgpt-mermaid-\_r_181\_ .node .label text,#chatgpt-mermaid-\_r_181\_ .image-shape .label,#chatgpt-mermaid-\_r_181\_ .icon-shape .label{text-anchor:middle;}#chatgpt-mermaid-\_r_181\_ .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .rough-node .label,#chatgpt-mermaid-\_r_181\_ .node .label,#chatgpt-mermaid-\_r_181\_ .image-shape .label,#chatgpt-mermaid-\_r_181\_ .icon-shape .label{text-align:center;}#chatgpt-mermaid-\_r_181\_ .node.clickable{cursor:pointer;}#chatgpt-mermaid-\_r_181\_ .root .anchor path{fill:rgb(143, 143, 143)!important;stroke-width:0;stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_181\_ .arrowheadPath{fill:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_181\_ .edgePath .path{stroke:rgb(143, 143, 143);stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .flowchart-link{stroke:rgb(143, 143, 143);fill:none;}#chatgpt-mermaid-\_r_181\_ .edgeLabel{background-color:rgb(252, 252, 252);text-align:center;}#chatgpt-mermaid-\_r_181\_ .edgeLabel p{background-color:rgb(252, 252, 252);}#chatgpt-mermaid-\_r_181\_ .edgeLabel rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252);}#chatgpt-mermaid-\_r_181\_ .labelBkg{background-color:rgba(252, 252, 252, 0.5);}#chatgpt-mermaid-\_r_181\_ .cluster rect{fill:rgb(243, 243, 243);stroke:rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .cluster text{fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ .cluster span{color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:12px;background:rgb(243, 243, 243);border:1px solid rgba(0, 0, 0, 0.1);border-radius:2px;pointer-events:none;z-index:100;}#chatgpt-mermaid-\_r_181\_ .flowchartTitleText{text-anchor:middle;font-size:18px;fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_181\_ rect.text{fill:none;stroke-width:0;}#chatgpt-mermaid-\_r_181\_ .icon-shape,#chatgpt-mermaid-\_r_181\_ .image-shape{background-color:rgb(252, 252, 252);text-align:center;}#chatgpt-mermaid-\_r_181\_ .icon-shape p,#chatgpt-mermaid-\_r_181\_ .image-shape p{background-color:rgb(252, 252, 252);padding:2px;}#chatgpt-mermaid-\_r_181\_ .icon-shape .label rect,#chatgpt-mermaid-\_r_181\_ .image-shape .label rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252);}#chatgpt-mermaid-\_r_181\_ .label-icon{display:inline-block;height:1em;overflow:visible;vertical-align:-0.125em;}#chatgpt-mermaid-\_r_181\_ .node .label-icon path{fill:currentColor;stroke:revert;stroke-width:revert;}#chatgpt-mermaid-\_r_181\_ .node .neo-node{stroke:rgb(83, 154, 248);}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node rect,#chatgpt-mermaid-\_r_181\_ [data-look="neo"].cluster rect,#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node polygon{stroke:url(#chatgpt-mermaid-\_r_181\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].swimlane.cluster rect{filter:none;}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node path{stroke:url(#chatgpt-mermaid-\_r_181\_-gradient);stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node .outer-path{filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node .neo-line path{stroke:rgb(83, 154, 248);filter:none;}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node circle{stroke:url(#chatgpt-mermaid-\_r_181\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].node circle .state-start{fill:#000000;}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].icon-shape .icon{fill:url(#chatgpt-mermaid-\_r_181\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_181\_ [data-look="neo"].icon-shape .icon-neo path{stroke:url(#chatgpt-mermaid-\_r_181\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_181\_ .node text{font-size:14px;font-weight:600;letter-spacing:normal;fill:rgb(65, 65, 65);}#chatgpt-mermaid-\_r_181\_ .edgeLabels text{font-size:13px;font-weight:600;letter-spacing:-0.08px;fill:rgb(65, 65, 65);}#chatgpt-mermaid-\_r_181\_ .node tspan[font-weight="normal"],#chatgpt-mermaid-\_r_181\_ .edgeLabels tspan[font-weight="normal"]{font-weight:600;}#chatgpt-mermaid-\_r_181\_ .edgeLabel .label rect{opacity:1;rx:13px;ry:13px;fill:rgb(252, 252, 252);stroke:rgb(219, 219, 219);stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .node rect,#chatgpt-mermaid-\_r_181\_ .node circle,#chatgpt-mermaid-\_r_181\_ .node ellipse,#chatgpt-mermaid-\_r_181\_ .node polygon,#chatgpt-mermaid-\_r_181\_ .node path{fill:rgb(243, 243, 243);stroke:rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_181\_ .node rect{rx:16px;ry:16px;}#chatgpt-mermaid-\_r_181\_ .node.mermaid-decision .label-container{fill:rgb(249, 249, 249);stroke:rgb(219, 219, 219);stroke-dasharray:2,2;}#chatgpt-mermaid-\_r_181\_ .edgePaths .flowchart-link{stroke:rgb(143, 143, 143);stroke-width:1px;stroke-linecap:round;stroke-linejoin:round;}#chatgpt-mermaid-\_r_181\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_181\_ :root{--mermaid-font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";}Workspacespi-extensionsmorselSession: lucky-stoneSession: silver-riverSession: viewer-redesignPi Conversation

這樣既能支援一般資料夾，也能支援 Git worktree（將 worktree 當成獨立 Workspace）。

另外，多個 session 與多個同時運作的 Pi process 是不同需求。Coding Agent 應先確認現有 Mac companion 能否管理多個 process，再決定切換 session 的實作方式，避免 UI 已支援多工，但底層切換時意外停止 Agent。
