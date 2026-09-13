# Paste-to-Attach (⌘V image in composer) — Design

Date: 2026-08-30 · Status: approved by owner · Scope: Swift UI only

## Problem

Attaching an image today requires the paperclip → NSOpenPanel round trip.
Copying an image (screenshot, browser, Finder) and pasting with ⌘V does
nothing — the composer only accepts text.

## Design

Intercept ⌘V on the composer `TextField` via `.onKeyPress("v", modifiers:
.command)`. Resolve the clipboard in priority order:

1. **Copied image FILE** (Finder, `NSURL` file URLs only): if the extension
   is png/jpg/jpeg/webp, attach the URL directly.
2. **Raw image bytes**: `public.png` data as-is; TIFF data converted to PNG
   via `NSBitmapImageRep`. Written to a temp file
   (`wf-paste-<unixts>.png`) which becomes the attachment URL.
3. **Neither** → return `.ignored` so the system text paste proceeds.

When an image resolves: set the existing `attachmentURL` (same state the
paperclip writes) and return `.handled`. The existing two-step flow is
reused unchanged: attachment banner → optional caption → ⌘Enter/paper plane
sends image + caption.

Clipboard containing image AND text (browser copy): the image wins — the
WhatsApp Web convention, and the behavior the owner asked for.

Temp-file write failure: falls through to `.ignored` (pastes nothing;
clipboard has no text in that case). No toast — the failure mode is a full
disk, which surfaces everywhere else already.

## Not in scope

- Multiple attachments, non-image types, drag-and-drop (existing behavior
  unchanged; clipboard PDFs ignored).
- Backend changes: `sendAttachment` already handles png/jpg/webp by
  extension.

## Contingency

If `onKeyPress` proves not to intercept ⌘V before the text system (verified
by manual test on the real app), fall back to an `NSEvent` local monitor in
`ComposerBar` (`keyDown` with ⌘V while the field is focused) — same
resolution logic, same attach path.

## Testing

No Swift unit-test target exists (tracked as audit debt). Verification =
build green + manual matrix on the real app: screenshot clipboard → banner
appears, send works; Finder file copy → attaches; text-only clipboard →
normal paste; browser image copy → image attaches.
