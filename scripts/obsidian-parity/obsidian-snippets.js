(async () => {
  const cases = [
    '**#bold** text', '==#mark== text', '~~#del~~ text', '(#paren) text', '[#bracket] text', '"#quote" text',
    '| a | b |\n|---|---|\n| #cell | x |', '- #listtag', '## Head #htag', '中文#标签 x', '#读书笔记，今天读完了', '#a#b #c+#d',
    'A$220 = A$200 + 10%', 'see https://a.com/x. and https://b.com/y，然后', '_https://u.com_', '#1 #2026 #7（备注）',
  ];
  const f = app.vault.getMarkdownFiles()[0];
  const out = [];
  for (const md of cases) {
    const div = document.createElement('div'); document.body.appendChild(div);
    div.style.cssText = 'position:fixed;left:-30000px;top:0;width:800px';
    const e = app.embedRegistry.embedByExtension.md({app, containerEl: div, sourcePath: f.path, linktext: f.path, displayMode: false}, f, '');
    e.editable = false; e.requestSave = () => {}; e.save = () => {};
    e.load(); await e.loadFile(f);
    e.previewMode.renderer.set(md);
    await new Promise(x => setTimeout(x, 400));
    const tags = [...div.querySelectorAll('a.tag')].map(a => a.textContent);
    const links = [...div.querySelectorAll('a.external-link')].map(a => a.getAttribute('href'));
    const math = div.querySelectorAll('.math').length;
    out.push(JSON.stringify(md) + ' => tags=' + JSON.stringify(tags) + ' links=' + JSON.stringify(links) + ' math=' + math);
    e.unload(); div.remove();
  }
  return out.join('\n');
})()
