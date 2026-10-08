# Telegram attachments — future plan

Deferred under the owner rule "defer complexity to a future plan". Each item says why it waited, the
design, the tests that would prove it, and what the owner must decide.

## 1. Extracted content in later turns

**Why deferred:** history is snapshotted from request payloads at admission, before the worker reads the
file, so later turns see `[PDF: report.pdf]` and the assistant's reply, not the content. Carrying it
needs a write-back path from the worker into what history is built from.

**Design:** a read-only `read_attachment` work tool over the current conversation's attachment
receipts (journaled `attachment.read` results), listed in the opening as `attachments: report.pdf (r…)`.
The model pulls the text again when a follow-up needs it; nothing is re-extracted. A voice transcript
also becomes the request's history line via the same receipt.
**Tests:** a follow-up question about page 2 of a PDF sent two turns earlier is answered (real model);
the tool refuses an attachment from another conversation.
**Owner decision:** whether transcripts should replace the `[voice message]` label in history.

## 2. Scanned PDFs and better OCR

**Why deferred:** needs rasterizing PDF pages (poppler/mupdf host tools or a heavy gem) and one vision
call per page with a page budget.
**Design:** for a PDF with no text layer, render up to N pages to PNG and send each through the P4
vision read, joined with page markers; budget N=5 by default.
**Tests:** scanned 3-page fixture → the hidden word on page 3 appears in the reply.

## 3. Attachment retention

**Why deferred:** files are bounded per file (20 MB) and the bot has one owner; a policy needs a choice.
**Design:** delete a stored file once every request referencing it is terminal and its `attachment.read`
receipt is recorded (the receipt is what replay uses), or after N days, whichever the owner picks.
**Owner decision:** retention period, and whether a deleted file may still be re-read by §1's tool.

## 4. Office formats (docx, xlsx, pptx)

**Why deferred:** each is a zip of XML with its own text model; no request asked for one yet.
**Design:** `docx` via `word/document.xml` paragraphs with nokogiri (already a dependency of
`tamoz-mcp-websearch`, not of the session); xlsx as CSV per sheet.

## 5. A separate vision model

**Why deferred:** the owner's chat model reads images (probe 2026-10-09).
**Design:** `TAMOZ_VISION_PROVIDER` / `TAMOZ_VISION_MODEL`, built like the transcription model; the
image read uses it when set.

## 6. Voice replies

**Design:** text-to-speech of the final answer when the user spoke, sent with `sendVoice` through the
outbox as a second delivery kind. Needs a delivery shape for bytes (today deliveries are text).

## 7. Albums and several files in one message

Telegram sends an album as several updates sharing `media_group_id`. Today each is its own request.
**Design:** the gateway holds updates with one `media_group_id` for a short window and admits one
request carrying several attachments. Needs a hold state in the gateway.

## 8. Hardening left for later

- **Memory bound for the PDF child on macOS.** `RLIMIT_AS` is not enforced there, so a decompression
  bomb is contained only by killing the child at its wall clock. On Linux, add `RLIMIT_AS`.
- **A per-pass download budget.** With one owner bot a burst of large files is unlikely; if one appears,
  cap downloads per poll pass and admit the rest on the next pass.
- **Albums** are §7.
