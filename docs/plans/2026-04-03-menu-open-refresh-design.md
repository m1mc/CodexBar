# Menu Open Refresh Design

Date: 2026-04-03

## Summary

This change restores a limited automatic refresh flow for the menu bar panel without bringing back background polling.

The menu content should refresh once each time the menu bar window is opened to the foreground. The existing manual refresh button remains available, and no additional timer-based refresh behavior is introduced.

## Goals

- Refresh account/quota data when the menu bar panel is opened.
- Reuse the existing `refresh()` path instead of creating a second refresh implementation.
- Ensure a single presentation only triggers one automatic refresh.
- Keep the current manual refresh button behavior unchanged.

## Non-Goals

- Do not reintroduce periodic background refresh.
- Do not change account-switching behavior.
- Do not add new dependencies or window-manager abstractions.

## Approach

Use the root `MenuBarView` presentation lifecycle as the trigger:

- On `onAppear`, mark the active account and trigger one automatic refresh for the current presentation.
- Track whether the current presentation has already triggered its automatic refresh with a local state flag.
- On `onDisappear`, reset the flag so the next open triggers a new refresh.

This is the smallest change because `MenuBarExtra` already creates a clear open/close lifecycle for the menu window, and `MenuBarView` already owns the user-facing refresh state.

## Trade-Offs

- This relies on the menu view lifecycle rather than lower-level AppKit window notifications.
- If the menu is reopened while a previous refresh is still running, the existing in-flight refresh is treated as sufficient and no second refresh is queued immediately.

## Verification

- Open the menu bar panel and confirm the refresh spinner starts automatically.
- Close and reopen the panel and confirm the automatic refresh happens again.
- Leave the panel open and confirm it does not continue refreshing repeatedly without user action.
