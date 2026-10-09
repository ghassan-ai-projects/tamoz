// The only code that puts message text on the page, and it only ever sets textContent.
const FENCE = /^\s*(```|~~~)/;

export function blocks(text) {
  const out = [];
  let code = null;
  let prose = [];
  const flush = () => {
    if (prose.length) out.push({ type: 'p', text: prose.join('\n').trim() });
    prose = [];
  };
  for (const line of String(text || '').split('\n')) {
    if (FENCE.test(line)) {
      if (code === null) {
        flush();
        code = [];
      } else {
        out.push({ type: 'pre', text: code.join('\n') });
        code = null;
      }
    } else if (code !== null) {
      code.push(line);
    } else if (line.trim() === '') {
      flush();
    } else {
      prose.push(line);
    }
  }
  if (code !== null) out.push({ type: 'pre', text: code.join('\n') });
  flush();
  return out.filter((b) => b.text.length || b.type === 'pre');
}

export function render(doc, container, text) {
  container.replaceChildren();
  for (const block of blocks(text)) {
    const node = doc.createElement(block.type);
    node.textContent = block.text;
    container.appendChild(node);
  }
  return container;
}
