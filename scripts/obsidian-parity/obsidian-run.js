// Renders each sampled note with Obsidian's own preview renderer into a
// detached, off-screen element (read-only: saving is stubbed out) and records
// per-note element counts. Started without awaiting; progress in progress.txt.
(() => {
  const fs = require('fs');
  const dir = '' + (window.__inkCmpDir || '/tmp/inkstone-parity/') + '';
  const sample = fs.readFileSync(dir + 'sample.txt', 'utf8').split('\n').filter(Boolean);
  const out = dir + 'obsidian.jsonl';
  fs.writeFileSync(out, '');
  const top = (root, sel) => [...root.querySelectorAll(sel)].filter(el => !el.parentElement.closest('.internal-embed'));
  const count = (root) => {
    const q = s => top(root, s).length;
    return {
      h: q('h1,h2,h3,h4,h5,h6'), li: q('li'), task: q('input.task-list-item-checkbox'),
      ilink: q('a.internal-link'), xlink: q('a.external-link'),
      code: top(root, 'pre').filter(p => !p.classList.contains('frontmatter') && !p.closest('.frontmatter-container,.metadata-container')).length,
      table: q('table'), tag: q('a.tag'), callout: q('.callout'), hr: q('hr'),
      math: q('.math'), mark: q('mark'), del: q('del'), embed: q('.internal-embed'),
      fn: q('sup.footnote-ref, sup[data-footnote-id]'), bq: q('blockquote'),
    };
  };
  window.__inkCmpStop = false;
  window.__inkCmp = (async () => {
    let done = 0;
    for (const path of sample) {
      if (window.__inkCmpStop) break;
      const f = app.vault.getAbstractFileByPath(path);
      let rec = { path };
      if (!f) { rec.missing = true; }
      else {
        const div = document.createElement('div'); document.body.appendChild(div);
        div.style.cssText = 'position:fixed;left:-30000px;top:0;width:800px';
        const e = app.embedRegistry.embedByExtension.md({ app, containerEl: div, sourcePath: f.path, linktext: f.path, displayMode: false }, f, '');
        e.editable = false; e.requestSave = () => {}; e.save = () => {};
        try {
          e.load(); await e.loadFile(f);
          const r = e.previewMode.renderer;
          let last = '', stable = 0;
          for (let i = 0; i < 400 && stable < 6; i++) {
            await new Promise(x => setTimeout(x, 50));
            const sig = r.sections.length + ':' + div.querySelectorAll('*').length;
            if (sig === last && !r.parsing) stable++; else stable = 0; last = sig;
          }
          rec.c = count(div);
        } catch (err) { rec.error = String(err); }
        try { e.unload(); } catch (_) {}
        div.remove();
      }
      fs.appendFileSync(out, JSON.stringify(rec) + '\n');
      done++;
      if (done % 20 === 0) fs.writeFileSync(dir + 'progress.txt', done + '/' + sample.length);
    }
    fs.writeFileSync(dir + 'progress.txt', 'done ' + done + '/' + sample.length);
  })();
  return 'started ' + sample.length;
})()
