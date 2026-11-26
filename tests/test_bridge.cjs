// Execute the actual desktop merge code with a fake DOM and a controlled snapshot request.
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('inbox.py', 'utf8');
const start = source.indexOf('  // Preserve open drafts, selection, and scroll position');
const code = source.slice(start, source.indexOf('  const foot = document.querySelector', start));
function context() {
  const c = { composing: null, draft: null, drag: null, picks: new Set(), pendingWrites: 0, revision: 0, search: '', searchHits: null,
    document: { hidden: false, activeElement: null, querySelectorAll: () => [], addEventListener: () => {} },
    setInterval: () => {}, setTimeout: () => {}, toast: () => {}, fail: e => { throw e; }, window: {},
    mail: [{ id: 9, a: 'work', gmailId: 'same' }, { id: 10, a: 'personal', gmailId: 'same' }], sel: 10,
    events: [], ev: e => e, REAL: {}, NOW: {}, undoFn: () => {}, evUndo: () => {}, undoAt: 0, threads: { 'work:t-new': 1, 'personal:t-same': 1 },
    render: () => { c.renders++; }, renders: 0, calls: 0,
    call: async path => { if (path === 'wait') return new Promise(() => {}); c.calls++; return { v: 4, mail: [{ id: 1, a: 'personal', gmailId: 'same', threadId: 't-same', unread: false }, { id: 2, a: 'work', gmailId: 'new', threadId: 't-new' }], events: [], base: [2026, 10, 3], now: { day: 1 } }; }
  };
  vm.createContext(c); vm.runInContext(code, c); return c;
}
(async () => {
  let c = context(); await c.syncSnapshot();
  assert.equal(c.sel, 10); assert.equal(c.mail[0].id, 10); assert.equal(c.mail[0].unread, false);
  assert.equal(c.mail[1].id, 11); assert.equal(c.renders, 1);
  assert.deepEqual(Object.keys(c.threads), ['personal:t-same']); // only the conversation with new mail is fetched again
  c = context(); c.undoFn = () => {}; c.undoAt = Date.now(); await c.syncSnapshot(); assert.equal(c.calls, 0); // Undo still showing
  c = context(); c.undoFn = () => {}; c.undoAt = Date.now(); await c.syncSnapshot(true); assert.equal(c.calls, 1); // Check for new mail goes ahead
  c = context(); c.composing = { body: 'keep my draft' }; await c.syncSnapshot(); assert.equal(c.calls, 0);
  c = context(); c.pendingWrites = 1; await c.syncSnapshot(); assert.equal(c.calls, 0);
  c = context(); c.searchHits = new Set([9]); await c.syncSnapshot(); assert.equal(c.calls, 0);
  c = context(); const fetch = c.call; c.call = async path => { const data = await fetch(path); c.revision++; return data; };
  await c.syncSnapshot(); assert.equal(c.renders, 0); assert.equal(c.mail[0].id, 9);
  console.log('Desktop merge: 7 scenarios passed (account identity, draft preservation, pending writes, open search, stale snapshot, Undo kept, manual check).');
})().catch(error => { console.error(error); process.exitCode = 1; });
