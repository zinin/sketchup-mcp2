// Exercise the existing settings contract and embedded live-log controls without SketchUp.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('mcp_for_sketchup/mcp_for_sketchup/ui/settings.html', 'utf8');
class Element {
  constructor() { this.value = ''; this.checked = false; this.disabled = false; this.children = []; this.events = {}; this.scrollTop = 0; this.scrollHeight = 0; this.clientHeight = 150; }
  set value(value) { this._value = String(value); }
  get value() { return this._value; }
  set textContent(value) { this.text = value; this.children = []; }
  get textContent() { return this.text || ''; }
  addEventListener(name, callback) { this.events[name] = callback; }
  appendChild(child) { this.children.push(child); }
}
const elements = Object.fromEntries([...html.matchAll(/\bid="([^"]+)"/g)].map(m => [m[1], new Element()]));
elements['live-log-level'].value = 'DEBUG';
const saves = [], polls = [], timers = [];
const context = { document: { hidden: false, getElementById: id => elements[id], createElement: () => new Element() },
  sketchup: { load_state() {}, load_logs(cursor) { polls.push(cursor); }, save(payload) { saves.push(JSON.parse(payload)); }, cancel() {} },
  setInterval(callback) { timers.push(callback); }, Date, JSON };
context.window = context;
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
const saved = { host: '127.0.0.1', port: 9876, log_level: 'WARN', log_to_file: false, log_file_path: '/tmp/mcp.log', eval_enabled: false, running: false };
context.applyState(saved);
assert.equal(elements['btn-save'].disabled, true);
elements.port.value = '9877';
elements.port.events.input();
assert.equal(elements['btn-save'].disabled, false);
elements['btn-save'].events.click();
assert.equal(saves[0].port, '9877');
assert.equal(saves[0].eval_enabled, 'false');
context.onSaveResult({ok: false, errors: {port: 'Invalid port'}});
assert.equal(elements['port-error'].textContent, 'Invalid port');
const hostile = '<img src=x onerror=alert(1)>';
context.appendLogs({cursor: 2, entries: [{id: 1, level: 'INFO', text: 'activity'}, {id: 2, level: 'ERROR', text: hostile}]});
assert.equal(elements['live-log-output'].children[1].textContent, hostile);
assert.equal(elements['live-log-output'].children[1].className, 'log-entry log-error');
elements['live-log-level'].value = 'WARN';
elements['live-log-level'].events.change();
assert.equal(elements['live-log-output'].children.length, 1);
elements['live-log-search'].value = 'not present';
elements['live-log-search'].events.input();
assert.equal(elements['live-log-output'].children.length, 0);
elements['live-log-clear'].events.click();
assert.equal(elements['live-log-output'].children.length, 0);
timers[0]();
assert.equal(polls.at(-1), '2'); // Clear does not replay old history.
assert.equal(saves.length, 1); // Log controls never save settings.
elements['live-log-search'].value = '';
elements['live-log-level'].value = 'DEBUG';
context.appendLogs({cursor: 252, entries: Array.from({length: 250}, (_, i) => ({id: i + 3, level: 'INFO', text: String(i)}))});
assert.equal(elements['live-log-output'].children.length, 200);
console.log('Settings save/validation contract, safe rendering, severity/search filters, clear cursor, and history bounds passed.');
