# wa.me Link Handling — Design

Date: 2026-08-30 · Status: approved by owner · Scope: macOS app only

## Problem

Clicking a `wa.me/<phone>` link ("Continue to Chat") should open the
conversation in this app, the way WhatsApp Desktop does.

## Mechanism

`wa.me` is HTTPS and its universal links are locked to Meta's apps — we
cannot claim it. The wa.me "Continue to Chat" button invokes the custom URL
scheme `whatsapp://send?phone=<digits>&text=<prefill>`. We register as a
handler for that scheme (plus our own conflict-free `whatsappwork://`
scheme) and open the target chat — same mechanism WhatsApp Desktop uses.

## Design

1. **Registration** (project.yml → Info.plist `CFBundleURLTypes`): schemes
   `whatsapp` and `whatsappwork`. xcodegen regenerates the project.
2. **Inbound link** (`.onOpenURL` on the root): parse
   `whatsapp://send?phone=&text=` (any of the registered schemes). Strip
   non-digits from phone → JID `<digits>@s.whatsapp.net`. If the chat is
   unknown, insert a minimal local placeholder row (name `+<digits>`) so the
   transcript opens; the server-side chat row appears on first send
   (`ensureChatFor`). `text=` becomes the composer draft and focuses the
   field.
3. **Default-handler button** (Account menu): `LSSetDefaultHandlerForURLScheme`
   for both schemes — resolves the conflict when official WhatsApp Desktop
   is also installed.
4. **Reverse direction** (free): context menu "Copy wa.me Link" on direct
   chats → `https://wa.me/<digits>` in the pasteboard + toast.

## Out of scope

Group invite links (`chat.whatsapp.com/…`) — they carry invite tokens, not
group JIDs; needs a separate invite-join flow.

## Testing

No Swift unit-test target (audit debt). Verification = build green,
`open 'whatsapp://send?phone=…'` launches app + opens the chat (CLI-triggered),
placeholder + prefill behave, context-menu link copies correct URL,
`whatsappwork://` path identical.
