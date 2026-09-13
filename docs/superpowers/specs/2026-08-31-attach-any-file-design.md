# Attach Any File — Design

Date: 2026-08-31 · Status: approved by owner · Scope: Swift UI only

## Problem

The composer's attach flow (paperclip, clipboard paste) only accepts images
(png/jpg/webp). Documents, video and audio must be sent elsewhere.

## Design

Backend already supports every kind (`mediaTypeFor`: image/video/audio →
matched type, anything else → document, 20 MB cap server-side). Changes are
client-side only:

1. **Attach panel**: any file (default NSOpenPanel file content types — no
   restriction). MIME resolved from the extension via
   `UTType(filenameExtension:).preferredMIMEType`, fallback
   `application/octet-stream` → sent as a document.
2. **20 MB client-side guard** before upload with a clear toast (mirrors the
   server cap; friendlier error).
3. **Attachment banner icon** by kind: photo / film / waveform / doc.
4. **⌘V paste**: the copied-FILE branch now accepts any file type (Finder
   copy → attach). The raw-bytes branch stays image-only (PNG, TIFF→PNG).
5. Captions apply to all kinds (WhatsApp documents and videos carry them;
   audio ignores them server-side).
6. Help text: "Attach file — pick now, type a caption, send together".

## Testing

Build green + manual matrix: PDF/DOCX/MP4/MP3 attach via paperclip and via
Finder-copy ⌘V; oversize file (>20 MB) shows the toast; image flow unchanged.
