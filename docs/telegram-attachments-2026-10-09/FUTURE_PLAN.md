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

## 3. Keeping attachments, only when asked

**Owner rule (2026-10-09):** attachments are not stored by default, and never in the database. Today a
file exists only as a temporary handoff from the gateway to the worker and is deleted once read.
**Design:** keep a file in a data folder under the runtime (never the database) only when the user asks
("keep this file") or an operator policy names the kinds to keep, the policy being data beside the
approval policy. A kept file is then readable by later turns (§1).
**Owner decision:** the policy's shape and how long kept files live.

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
- **A sandbox for the PDF reader.** `pdftotext` runs bounded in time, CPU and output with a clean
  environment, but as the worker's user; a poppler exploit could read the runtime directory. Wrap it
  (`bwrap` on Linux, `sandbox-exec` on macOS) when PDFs come from people other than the owner.
- **Downloads for a request that is then refused.** A file is fetched before `admit_and_enqueue` checks
  open requests and capacity; its temporary file is deleted at once, but the download was wasted.
- **Forwarded captions.** A forwarded document's caption becomes the turn's task, exactly as forwarded
  text does today. Framing every forwarded message as material is one change for both.
