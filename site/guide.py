#!/usr/bin/env python3
"""The sync guide, in the languages the app itself ships.

Structure lives here once; only the words differ per language. That is the same
split `build.py` makes for the marketing pages, and for the same reason: three
hand-written copies of one page drift, and the drift is invisible until someone
who reads that language looks.

Not part of build.py's eight-language system, deliberately. That system fails the
build unless *every* page exists in *all eight*, which is right for marketing
copy and wrong for a help page the app links to: the app ships three
localisations, and promising a French guide it does not have would be worse than
sending a French reader to the English one.

Emitted into the same language directories the rest of the site uses, so
`SyncHelp.url(for:)` in the app can be a prefix and a filename.
"""
from __future__ import annotations

from dataclasses import dataclass

# lang → (directory prefix, html lang attribute, label)
LANGS = {
    "en": ("", "en", "English"),
    "zh": ("zh/", "zh-Hans", "简体中文"),
    "zh-Hant": ("zh-Hant/", "zh-Hant", "繁體中文"),
}
DEFAULT = "en"


@dataclass(frozen=True)
class Shot:
    name: str
    width: int
    height: int


SHOTS = {
    "settings": Shot("sync-settings", 1120, 1096),
    "git": Shot("sync-git-guard", 1120, 1096),
    "conflict": Shot("sync-conflict-copies", 620, 880),
}

STYLE = """
  .doc { max-width: 42rem; margin-inline: auto; padding-block: clamp(3rem, 7vw, 6rem); }
  .doc h1 { font-size: var(--t-h2); font-weight: 400; letter-spacing: -.02em; line-height: 1.15; }
  .doc h2 { font-size: var(--t-h3); font-weight: 600; margin-top: 3rem; margin-bottom: .6rem; }
  .doc h3 { font-size: var(--t-body); font-weight: 600; margin-top: 1.8rem; margin-bottom: .4rem; }
  .doc p, .doc li, .doc td { color: var(--ink-2); }
  .doc p { margin-block: .9rem; }
  .doc h2 + p, .doc h3 + p { margin-top: 0; }
  .doc ul, .doc ol { padding-inline-start: 1.2rem; margin-block: .8rem; }
  .doc ul { list-style: disc; }
  .doc ol { list-style: decimal; }
  .doc li { margin-block: .4rem; }
  .doc .updated { font-family: var(--sans); font-size: var(--t-micro);
                  letter-spacing: .14em; text-transform: uppercase;
                  color: var(--ink-faint); margin-bottom: 1.4rem; }
  .doc table { width: 100%; border-collapse: collapse; margin-block: 1.2rem;
               font-size: var(--t-small); }
  .doc th { text-align: left; font-family: var(--sans); font-size: var(--t-micro);
            letter-spacing: .1em; text-transform: uppercase; color: var(--ink-faint);
            font-weight: 500; padding: .5rem .8rem .5rem 0;
            border-bottom: 1px solid var(--rule); }
  .doc td { padding: .7rem .8rem .7rem 0; border-bottom: 1px solid var(--rule);
            vertical-align: top; }
  .doc td:last-child, .doc th:last-child { padding-right: 0; }
  .doc .rule-box { border-inline-start: 2px solid var(--ink-faint);
                   padding-inline-start: 1.1rem; margin-block: 1.4rem; }
  .doc .rule-box p:first-child { margin-top: 0; }
  .doc .rule-box p:last-child { margin-bottom: 0; }
  .doc figure { margin: 1.8rem 0; color: var(--ink-2); }
  .doc figure img { display: block; width: 100%; height: auto; border-radius: 8px;
                    border: 1px solid var(--rule); }
  /* Shown near the size the window actually is — a 560pt panel blown up to
     the full measure reads as a diagram rather than as a screenshot. */
  .doc figure.window img { max-width: 30rem; }
  .doc figure.narrow img { max-width: 19rem; }
  .doc figcaption { font-family: var(--sans); font-size: var(--t-micro);
                    color: var(--ink-faint); margin-top: .6rem; }
  .doc figure svg text { font-family: var(--sans); }
  .doc .langs { font-family: var(--sans); font-size: var(--t-micro);
                letter-spacing: .1em; text-transform: uppercase;
                color: var(--ink-faint); margin-bottom: 1.4rem; }
  .doc .langs a { margin-inline-end: .9rem; }
  .doc .home { font-family: var(--sans); font-size: var(--t-small);
               display: inline-block; margin-top: 3rem; }
"""


def diagram(desktop: str, phone: str, repository: str, git_label: str,
            sync_label: str, alt: str) -> str:
    """One writer per mechanism, as a drawing.

    An SVG rather than the box-drawing characters this started as: those rely on
    the monospace font having consistent widths for `─` and `│`, and in the
    site's stack they do not — the lines came out broken.
    """
    return f"""  <figure aria-label="{alt}">
    <svg viewBox="0 0 600 150" role="img" width="100%" style="max-width:36rem;height:auto">
      <g fill="none" stroke="currentColor" stroke-width="1" opacity=".3">
        <path d="M252 30 H440"/><path d="M252 120 H440"/>
        <path d="M440 30 V120"/><path d="M440 75 H464"/>
      </g>
      <g fill="currentColor" font-size="12">
        <text x="0" y="34" opacity=".5" letter-spacing=".1em">{desktop}</text>
        <text x="0" y="124" opacity=".5" letter-spacing=".1em">{phone}</text>
        <text x="266" y="21" opacity=".6">{git_label}</text>
        <text x="266" y="111" opacity=".6">{sync_label}</text>
        <text x="472" y="79" font-size="13">{repository}</text>
      </g>
    </svg>
  </figure>"""


def figure(shot: Shot, caption: str, up: str, kind: str = "window") -> str:
    cls = f' class="{kind}"' if kind else ""
    return f"""  <figure{cls}>
    <picture>
      <source srcset="{up}assets/guide/{shot.name}.webp" type="image/webp">
      <img src="{up}assets/guide/{shot.name}.png" alt="{caption}"
           width="{shot.width}" height="{shot.height}" loading="lazy" decoding="async">
    </picture>
    <figcaption>{caption}</figcaption>
  </figure>"""


# --------------------------------------------------------------- the content
#
# Every language supplies the same keys. `render` reads them positionally, so a
# missing one is a KeyError at build time rather than a gap on a published page.

CONTENT = {
    "en": {
        "lang_label": "English",
        "title": "Syncing a vault — Inkstone",
        "description": "How to keep an Inkstone vault on more than one device, with iCloud Drive or a GitHub repository — what each is good at, how to set it up, and exactly when a conflict happens.",
        "updated": "Updated 23 August 2026",
        "h1": "Syncing a vault",
        "intro": "A vault is a folder of Markdown files. Nothing about it is proprietary, so there is more than one sensible way to get it onto a second device. Inkstone offers two, and they are good at different things.",
        "table_head": ["", "iCloud Drive", "GitHub"],
        "table_rows": [
            ["Set-up", "Put the folder in iCloud Drive", "A repository and an access token"],
            ["Speed", "Seconds", "Minutes, on a schedule"],
            ["History", "None you can browse", "Every change, as commits"],
            ["Works with", "Your Apple devices", "Anything that can reach GitHub"],
            ["Costs", "iCloud storage", "Free for private repositories"],
        ],
        "both": "They are not exclusive. A vault can sit in iCloud Drive <em>and</em> push to GitHub; iCloud moves it between your own devices quickly, GitHub keeps the history and the off-Apple copy.",
        "icloud_h": "iCloud Drive",
        "icloud_1": "There is no switch to turn on. Put the vault folder in iCloud Drive and open it, and iCloud does the rest — it is the system moving files, not Inkstone.",
        "icloud_2": "The one setting that exists is <strong>Keep files downloaded</strong>, and it is on by default. iCloud saves disk space by evicting the contents of files you have not opened recently, leaving a placeholder behind. To Inkstone a placeholder is an empty note, so a vault that has been sitting idle can look like a vault that has lost its notes. Turn it off only on a machine genuinely short of disk.",
        "icloud_box": "<strong>iCloud makes its own conflict copies.</strong> If the same file is edited on two devices before either has finished syncing, iCloud keeps both and marks one. That is Apple's mechanism, not Inkstone's, and it looks different from the ones below.",
        "github_h": "GitHub",
        "github_1": "You need a repository — private is fine, and normal — and a fine-grained personal access token with <strong>Contents: read and write</strong> for that repository. The token is stored in your Keychain, never in the vault and never in the settings file.",
        "shot_settings": "Settings › Sync, with a repository and branch set",
        "first_h": "First device",
        "first_steps": [
            "Open the vault you want to sync.",
            "Settings › Sync, turn on <strong>Sync this vault with GitHub</strong>.",
            "Paste the token, choose the repository and branch.",
            "<strong>Sync now</strong>.",
        ],
        "second_h": "Second device",
        "second_lede": "Start with an <strong>empty folder</strong>. This matters more than anything else on this page.",
        "second_steps": [
            "Make a new, empty folder and open it as a vault.",
            "Enter the same repository and branch.",
            "Sync. You will be asked which side wins — choose <strong>Keep GitHub's</strong>.",
        ],
        "second_why": "Pointing a folder that already has notes in it at a repository that has different notes in it is asking two unrelated sets of files to become one. The app cannot know which is which, so it keeps both, and you get a conflict copy of every file that differs.",
        "binding_box": "<strong>The repository belongs to the vault, not to the app.</strong> Each vault has its own repository setting. Opening a different vault does not inherit the last one's, and a vault that has not been given a repository does not sync at all.",
        "conflict_h": "When a conflict happens",
        "conflict_lede": "Exactly one situation produces one:",
        "conflict_rule": "The same file was changed <strong>on both devices</strong> since the last time they agreed.",
        "conflict_1": "That is the whole rule. Each sync compares three things for every file: what is here, what is on GitHub, and what the last completed sync recorded. If only one side moved, that side wins and nothing is ambiguous. If both moved, there is no answer the app can pick for you.",
        "conflict_which": "Which means:",
        "conflict_points": [
            "Editing on one device, letting it sync, then editing on the other — <strong>never conflicts</strong>, however long you leave it.",
            "Editing <em>different</em> notes on two devices — never conflicts, however stale either side is.",
            "Editing the <em>same</em> note on two devices before a sync — conflicts, and should.",
        ],
        "conflict_2": "<strong>A conflict never overwrites anything.</strong> GitHub's copy is written beside yours as <code>Note (conflict 2026-08-23 1420).md</code> and both survive. Open them, keep what you want, delete the other. The copy is made once, not once per sync.",
        "shot_conflict": "A conflict copy sitting beside the note it came from",
        "first_sync_h": "The first sync is the exception",
        "first_sync_p": "Before the first sync there is no record of the two sides ever agreeing, so every file that exists on both and differs looks like “both changed”. Rather than making a conflict copy of each, the app asks you once — keep this device's, keep GitHub's, or keep both — and remembers the answer.",
        "fewer_h": "Having fewer of them",
        "fewer_points": [
            "<strong>Sync before you switch devices.</strong> On iOS the sync keeps running after you leave the app, and the system shows its progress until it finishes.",
            "<strong>Let the phone finish before you edit on it.</strong> The Sync pane shows a progress bar and a file count while it works.",
        ],
        "often_h": "How often it actually runs",
        "often_1": "The interval you choose is a floor, not a promise.",
        "often_2": "On macOS the app is running, so it holds. On iOS the system decides: it budgets background time from how often you open the app, and it will not wake an app you have force-quit from the app switcher until you open it again. Expect a few background runs a day rather than one every interval. Background App Refresh must be on, and Low Power Mode suspends it entirely.",
        "often_3": "Settings › Sync shows what the system has actually been doing — when it last woke the app, and a log of each attempt.",
        "git_h": "If the vault is a git working copy",
        "git_1": "If the folder has a <code>.git</code> directory in it, Inkstone's GitHub sync switches itself off and says so.",
        "shot_git": "The notice shown for a vault git already syncs",
        "git_2": "This is not a limitation, it is the two mechanisms disagreeing. Git merges: three-way, with a history, and conflict markers a person resolves. Inkstone's sync works file by file and last write wins. Run both over one folder and each undoes the other's results.",
        "git_3": "The arrangement that works is one writer per mechanism:",
        "diagram": ("DESKTOP", "PHONE", "repository", "git pull / push", "Inkstone sync",
                    "Git on the desktop and Inkstone on the phone, both reaching one repository"),
        "git_4": "Git on the desktop, Inkstone on the phone. The phone's changes arrive on the desktop through <code>git pull</code>; the desktop's reach the phone once pushed. Pull before you commit — the phone writes to the same branch.",
        "git_5": "There is a per-vault override if you want to sync a git working copy anyway. It is off unless you ask for it.",
        "refuse_h": "What Inkstone refuses to do",
        "refuse_lede": "A few situations look like an instruction and are almost always an accident, so the sync stops instead of carrying them out.",
        "refuse_points": [
            "<strong>The repository has gone empty</strong> but files were recorded there before. An empty listing is far more often a wrong branch or a token that lost access than a deliberate wipe — and the response to a deleted remote file is to delete the local one.",
            "<strong>The branch does not exist.</strong> The message names the branches that do.",
            "<strong>The vault is a git working copy</strong>, as above.",
        ],
        "refuse_tail": "An interrupted sync is safe: what it moved is kept and the next run continues from there rather than starting over.",
        "files_h": "Which files travel",
        "files_1": "Notes and canvases always sync. Attachments sync by kind — images, audio, PDFs, video, everything else — each with its own switch, plus a size limit. Settings › Sync has them.",
        "files_2": "A <code>.gitignore</code> in the vault root is obeyed, and travels with the vault, so a second device gets the same rules rather than uploading everything the first one deliberately left out.",
        "home": "← Inkstone",
    },
}


CONTENT["zh"] = {'lang_label': '简体中文',
 'title': '同步你的 vault — Inkstone',
 'description': '如何让一个 Inkstone vault 出现在多台设备上：iCloud Drive 和 GitHub 各擅长什么、怎么设置，以及冲突到底在什么情况下才会发生。',
 'updated': '更新于 2026 年 8 月 23 日',
 'h1': '同步你的 vault',
 'intro': 'vault 就是一个装着 Markdown 文件的文件夹，没有任何私有格式，所以把它弄到第二台设备上的合理办法不止一种。Inkstone 提供两种，各有各的长处。',
 'table_head': ['', 'iCloud Drive', 'GitHub'],
 'table_rows': [['设置', '把文件夹放进 iCloud Drive', '一个仓库和一个访问令牌'],
                ['速度', '几秒', '几分钟，按计划执行'],
                ['历史', '无法翻阅', '每一次改动都是一个提交'],
                ['适用于', '你自己的 Apple 设备', '任何能访问 GitHub 的东西'],
                ['成本', 'iCloud 存储空间', '私有仓库免费']],
 'both': '两者并不互斥。一个 vault 可以既放在 iCloud Drive 里，<em>又</em>推送到 GitHub——iCloud 在你自己的设备之间搬得快，GitHub '
         '保留历史和一份不依赖 Apple 的副本。',
 'icloud_h': 'iCloud Drive',
 'icloud_1': '没有开关要打开。把 vault 文件夹放进 iCloud Drive 再打开它，剩下的 iCloud 会做——搬文件的是系统，不是 Inkstone。',
 'icloud_2': '唯一存在的设置是<strong>保持文件已下载</strong>，默认开启。iCloud 会把你最近没打开过的文件内容清掉以节省磁盘，只留一个占位符。而占位符在 '
             'Inkstone 看来就是一篇空笔记，所以一个闲置了一阵的 vault 会看起来像丢了笔记。只在磁盘真的紧张的机器上才关掉它。',
 'icloud_box': '<strong>iCloud 会产生它自己的冲突副本。</strong>如果同一个文件在两台设备上都被改过、而两边都还没同步完，iCloud '
               '会两份都留下并标记其中一份。那是 Apple 的机制，不是 Inkstone 的，长得也和下面说的不一样。',
 'github_h': 'GitHub',
 'github_1': '你需要一个仓库——私有的完全可以，而且很正常——以及一个细粒度个人访问令牌，对该仓库拥有 <strong>Contents: read and '
             'write</strong> 权限。令牌存在你的钥匙串里，绝不写进 vault，也绝不写进设置文件。',
 'shot_settings': '设置 › Sync，已填好仓库与分支',
 'first_h': '第一台设备',
 'first_steps': ['打开你想同步的 vault。',
                 '设置 › Sync，打开 <strong>Sync this vault with GitHub</strong>。',
                 '粘贴令牌，选择仓库和分支。',
                 '点 <strong>Sync now</strong>。'],
 'second_h': '第二台设备',
 'second_lede': '从一个<strong>空文件夹</strong>开始。这一条比本页其他任何内容都重要。',
 'second_steps': ['新建一个空文件夹，把它作为 vault 打开。',
                  '填入同一个仓库和分支。',
                  "同步。它会问你哪一边算数——选 <strong>Keep GitHub's</strong>。"],
 'second_why': '把一个已经装着笔记的文件夹指向一个装着另一批笔记的仓库，等于要求两套不相干的文件合成一套。App '
               '无法知道哪个是哪个，于是两份都留下，每一个有差异的文件你都会得到一份冲突副本。',
 'binding_box': '<strong>仓库属于 vault，不属于 App。</strong>每个 vault 有自己的仓库设置。打开另一个 vault '
                '不会继承上一个的，而没有被指定仓库的 vault 根本不会同步。',
 'conflict_h': '冲突什么时候发生',
 'conflict_lede': '只有一种情况会产生冲突：',
 'conflict_rule': '同一个文件，自两边上次达成一致以来，<strong>在两台设备上都被改过</strong>。',
 'conflict_1': '规则就这一条。每次同步会为每个文件比较三样东西：这里是什么、GitHub '
               '上是什么、以及上一次完成的同步记录了什么。如果只有一边动了，那一边胜出，毫无歧义。如果两边都动了，就没有任何 App 能替你选的答案。',
 'conflict_which': '也就是说：',
 'conflict_points': ['在一台上改、等它同步完、再用另一台——<strong>永远不冲突</strong>，隔多久都一样。',
                     '在两台设备上改<em>不同</em>的笔记——永远不冲突，哪怕一边很旧。',
                     '在同步之前，两台设备上改<em>同一篇</em>笔记——会冲突，也应该冲突。'],
 'conflict_2': '<strong>冲突绝不覆盖任何东西。</strong>GitHub 那一份会写在你这份旁边，名字是 <code>笔记 (conflict 2026-08-23 '
               '1420).md</code>，两份都在。打开它们，留下你要的，删掉另一份。副本只生成一次，不是每次同步生成一次。',
 'shot_conflict': '冲突副本就放在它来源的那篇笔记旁边',
 'first_sync_h': '首次同步是例外',
 'first_sync_p': '首次同步之前，没有任何「两边曾经一致」的记录，所以每一个两边都存在且有差异的文件都像是「都改过」。它不会为每个文件都造一份冲突副本，而是问你一次——留本机的、留 '
                 'GitHub 的、还是两个都留——然后记住这个答案。',
 'fewer_h': '怎么少遇到冲突',
 'fewer_points': ['<strong>换设备之前先同步。</strong>在 iOS 上，同步会在你离开 App 之后继续跑，系统会一直显示进度直到跑完。',
                  '<strong>在手机上编辑之前，先让它把同步跑完。</strong>Sync 面板在工作时会显示进度条和文件计数。'],
 'often_h': '它实际多久跑一次',
 'often_1': '你选的间隔是下限，不是承诺。',
 'often_2': '在 macOS 上 App 一直在运行，所以间隔是准的。在 iOS 上由系统决定：它根据你打开 App 的频率来分配后台时间，而且如果你从多任务卡片里划掉了 '
            'App，在你再次打开它之前系统不会唤醒它。预期是一天几次后台运行，而不是每个间隔一次。「后台 App 刷新」必须开启，低电量模式会完全暂停它。',
 'often_3': '设置 › Sync 会显示系统实际做了什么——上次唤醒 App 是什么时候，以及每一次尝试的记录。',
 'git_h': '如果这个 vault 是 git 工作树',
 'git_1': '如果文件夹里有 <code>.git</code> 目录，Inkstone 的 GitHub 同步会自动关闭，并说明原因。',
 'shot_git': '对一个 git 已经在同步的 vault 显示的提示',
 'git_2': '这不是限制，而是两套机制在打架。git 会合并：三方合并、有历史、冲突标记由人来解决。Inkstone '
          '的同步是逐文件、后写覆盖先写。让两者在同一个文件夹上跑，各自会撤销对方的结果。',
 'git_3': '行得通的安排是每套机制只有一个写入方：',
 'diagram': ('桌面端',
             '手机端',
             '仓库',
             'git pull / push',
             'Inkstone 同步',
             '桌面端走 git、手机端走 Inkstone，共同指向一个仓库'),
 'git_4': '桌面端用 git，手机端用 Inkstone。手机的改动通过 <code>git pull</code> 到达桌面；桌面的改动推送之后到达手机。提交之前先 '
          'pull——手机也在往同一个分支写。',
 'git_5': '如果你确实想同步一个 git 工作树，有一个针对单个 vault 的覆盖开关。不主动打开它就一直是关的。',
 'refuse_h': 'Inkstone 拒绝做的事',
 'refuse_lede': '有几种情况看起来像是一条指令，但几乎总是意外，所以同步会停下来而不是照做。',
 'refuse_points': ['<strong>仓库变空了</strong>，但之前在那里记录过文件。空列表远远更可能是分支填错了或令牌掉了权限，而不是有人真的清空了它——而对「远端文件被删」的正确反应是删掉本地那份。',
                   '<strong>分支不存在。</strong>报错会列出实际存在的分支。',
                   '<strong>这个 vault 是 git 工作树</strong>，见上。'],
 'refuse_tail': '被打断的同步是安全的：已经搬过去的会保留，下一次从那里继续，而不是重头再来。',
 'files_h': '哪些文件会被同步',
 'files_1': '笔记和白板永远同步。附件按类型同步——图片、音频、PDF、视频、其他文件——每一类有自己的开关，另有一个体积上限。都在设置 › Sync 里。',
 'files_2': 'vault 根目录下的 <code>.gitignore</code> 会被遵守，并且会跟着 vault '
            '一起同步，所以第二台设备拿到的是同一套规则，而不是把第一台刻意排除掉的东西全都传上去。',
 'home': '← Inkstone'}

CONTENT["zh-Hant"] = {'lang_label': '繁體中文',
 'title': '同步你的 vault — Inkstone',
 'description': '如何讓一個 Inkstone vault 出現在多台裝置上：iCloud 雲碟與 GitHub 各自擅長什麼、怎麼設定，以及衝突到底在什麼情況下才會發生。',
 'updated': '更新於 2026 年 8 月 23 日',
 'h1': '同步你的 vault',
 'intro': 'vault 就是一個裝著 Markdown 檔案的資料夾，沒有任何專有格式，所以把它弄到第二台裝置上的合理做法不只一種。Inkstone 提供兩種，各有各的長處。',
 'table_head': ['', 'iCloud 雲碟', 'GitHub'],
 'table_rows': [['設定', '把資料夾放進 iCloud 雲碟', '一個儲存庫和一個存取權杖'],
                ['速度', '幾秒', '幾分鐘，按排程執行'],
                ['歷史', '無法翻閱', '每一次變更都是一個提交'],
                ['適用於', '你自己的 Apple 裝置', '任何能連上 GitHub 的東西'],
                ['成本', 'iCloud 儲存空間', '私有儲存庫免費']],
 'both': '兩者並不互斥。一個 vault 可以既放在 iCloud 雲碟裡，<em>又</em>推送到 GitHub——iCloud 在你自己的裝置之間搬得快，GitHub '
         '保留歷史和一份不依賴 Apple 的副本。',
 'icloud_h': 'iCloud 雲碟',
 'icloud_1': '沒有開關要打開。把 vault 資料夾放進 iCloud 雲碟再打開它，剩下的 iCloud 會做——搬檔案的是系統，不是 Inkstone。',
 'icloud_2': '唯一存在的設定是<strong>保持檔案已下載</strong>，預設開啟。iCloud 會把你最近沒開過的檔案內容清掉以節省磁碟空間，只留一個佔位符。而佔位符在 '
             'Inkstone 看來就是一篇空筆記，所以一個閒置了一陣子的 vault 會看起來像是掉了筆記。只在磁碟真的吃緊的機器上才關掉它。',
 'icloud_box': '<strong>iCloud 會產生它自己的衝突副本。</strong>如果同一個檔案在兩台裝置上都被改過、而兩邊都還沒同步完，iCloud '
               '會兩份都留下並標記其中一份。那是 Apple 的機制，不是 Inkstone 的，長得也和下面說的不一樣。',
 'github_h': 'GitHub',
 'github_1': '你需要一個儲存庫——私有的完全可以，而且很正常——以及一個細粒度個人存取權杖，對該儲存庫擁有 <strong>Contents: read and '
             'write</strong> 權限。權杖存在你的鑰匙圈裡，絕不寫進 vault，也絕不寫進設定檔。',
 'shot_settings': '設定 › Sync，已填好儲存庫與分支',
 'first_h': '第一台裝置',
 'first_steps': ['打開你想同步的 vault。',
                 '設定 › Sync，開啟 <strong>Sync this vault with GitHub</strong>。',
                 '貼上權杖，選擇儲存庫和分支。',
                 '按 <strong>Sync now</strong>。'],
 'second_h': '第二台裝置',
 'second_lede': '從一個<strong>空資料夾</strong>開始。這一條比本頁其他任何內容都重要。',
 'second_steps': ['新建一個空資料夾，把它當作 vault 打開。',
                  '填入同一個儲存庫和分支。',
                  "同步。它會問你哪一邊算數——選 <strong>Keep GitHub's</strong>。"],
 'second_why': '把一個已經裝著筆記的資料夾指向一個裝著另一批筆記的儲存庫，等於要求兩套不相干的檔案合成一套。App '
               '無法知道哪個是哪個，於是兩份都留下，每一個有差異的檔案你都會拿到一份衝突副本。',
 'binding_box': '<strong>儲存庫屬於 vault，不屬於 App。</strong>每個 vault 有自己的儲存庫設定。打開另一個 vault '
                '不會繼承上一個的，而沒有被指定儲存庫的 vault 根本不會同步。',
 'conflict_h': '衝突什麼時候發生',
 'conflict_lede': '只有一種情況會產生衝突：',
 'conflict_rule': '同一個檔案，自兩邊上次達成一致以來，<strong>在兩台裝置上都被改過</strong>。',
 'conflict_1': '規則就這一條。每次同步會為每個檔案比較三樣東西：這裡是什麼、GitHub '
               '上是什麼、以及上一次完成的同步記錄了什麼。如果只有一邊動了，那一邊勝出，毫無歧義。如果兩邊都動了，就沒有任何 App 能替你選的答案。',
 'conflict_which': '也就是說：',
 'conflict_points': ['在一台上改、等它同步完、再用另一台——<strong>永遠不衝突</strong>，隔多久都一樣。',
                     '在兩台裝置上改<em>不同</em>的筆記——永遠不衝突，哪怕一邊很舊。',
                     '在同步之前，兩台裝置上改<em>同一篇</em>筆記——會衝突，也應該衝突。'],
 'conflict_2': '<strong>衝突絕不覆蓋任何東西。</strong>GitHub 那一份會寫在你這份旁邊，名字是 <code>筆記 (conflict 2026-08-23 '
               '1420).md</code>，兩份都在。打開它們，留下你要的，刪掉另一份。副本只產生一次，不是每次同步產生一次。',
 'shot_conflict': '衝突副本就放在它來源的那篇筆記旁邊',
 'first_sync_h': '首次同步是例外',
 'first_sync_p': '首次同步之前，沒有任何「兩邊曾經一致」的記錄，所以每一個兩邊都存在且有差異的檔案都像是「都改過」。它不會為每個檔案都造一份衝突副本，而是問你一次——留本機的、留 '
                 'GitHub 的、還是兩個都留——然後記住這個答案。',
 'fewer_h': '怎麼少遇到衝突',
 'fewer_points': ['<strong>換裝置之前先同步。</strong>在 iOS 上，同步會在你離開 App 之後繼續跑，系統會一直顯示進度直到跑完。',
                  '<strong>在手機上編輯之前，先讓它把同步跑完。</strong>Sync 面板在工作時會顯示進度列和檔案計數。'],
 'often_h': '它實際多久跑一次',
 'often_1': '你選的間隔是下限，不是承諾。',
 'often_2': '在 macOS 上 App 一直在執行，所以間隔是準的。在 iOS 上由系統決定：它根據你打開 App 的頻率來分配背景時間，而且如果你從 App 切換器裡滑掉了 '
            'App，在你再次打開它之前系統不會喚醒它。預期是一天幾次背景執行，而不是每個間隔一次。「背景 App 重新整理」必須開啟，低耗電模式會完全暫停它。',
 'often_3': '設定 › Sync 會顯示系統實際做了什麼——上次喚醒 App 是什麼時候，以及每一次嘗試的記錄。',
 'git_h': '如果這個 vault 是 git 工作副本',
 'git_1': '如果資料夾裡有 <code>.git</code> 目錄，Inkstone 的 GitHub 同步會自動關閉，並說明原因。',
 'shot_git': '對一個 git 已經在同步的 vault 顯示的提示',
 'git_2': '這不是限制，而是兩套機制在打架。git 會合併：三方合併、有歷史、衝突標記由人來解決。Inkstone '
          '的同步是逐檔案、後寫覆蓋先寫。讓兩者在同一個資料夾上跑，各自會撤銷對方的結果。',
 'git_3': '行得通的安排是每套機制只有一個寫入方：',
 'diagram': ('桌面端',
             '手機端',
             '儲存庫',
             'git pull / push',
             'Inkstone 同步',
             '桌面端走 git、手機端走 Inkstone，共同指向一個儲存庫'),
 'git_4': '桌面端用 git，手機端用 Inkstone。手機的變更透過 <code>git pull</code> 到達桌面；桌面的變更推送之後到達手機。提交之前先 '
          'pull——手機也在往同一個分支寫。',
 'git_5': '如果你確實想同步一個 git 工作副本，有一個針對單一 vault 的覆寫開關。不主動打開它就一直是關的。',
 'refuse_h': 'Inkstone 拒絕做的事',
 'refuse_lede': '有幾種情況看起來像是一條指令，但幾乎總是意外，所以同步會停下來而不是照做。',
 'refuse_points': ['<strong>儲存庫變空了</strong>，但之前在那裡記錄過檔案。空清單遠遠更可能是分支填錯了或權杖掉了權限，而不是有人真的清空了它——而對「遠端檔案被刪」的正確反應是刪掉本機那份。',
                   '<strong>分支不存在。</strong>錯誤訊息會列出實際存在的分支。',
                   '<strong>這個 vault 是 git 工作副本</strong>，見上。'],
 'refuse_tail': '被中斷的同步是安全的：已經搬過去的會保留，下一次從那裡繼續，而不是從頭再來。',
 'files_h': '哪些檔案會被同步',
 'files_1': '筆記和白板永遠同步。附件按類型同步——圖片、音訊、PDF、影片、其他檔案——每一類有自己的開關，另有一個容量上限。都在設定 › Sync 裡。',
 'files_2': 'vault 根目錄下的 <code>.gitignore</code> 會被遵守，並且會跟著 vault '
            '一起同步，所以第二台裝置拿到的是同一套規則，而不是把第一台刻意排除掉的東西全都傳上去。',
 'home': '← Inkstone'}


def render(lang: str, site: str, asset_hash) -> str:
    """One page, in one language. Structure comes from here, words from CONTENT."""
    c = CONTENT[lang]
    prefix, hreflang, _ = LANGS[lang]
    up = "../" if prefix else ""

    def p(text: str) -> str:
        return f"  <p>{text}</p>"

    def items(tag: str, entries) -> str:
        rows = "\n".join(f"    <li>{e}</li>" for e in entries)
        return f"  <{tag}>\n{rows}\n  </{tag}>"

    def box(text: str) -> str:
        return f'  <div class="rule-box">\n    <p>{text}</p>\n  </div>'

    head_cells = "".join(
        f"<th>{h or '&nbsp;'}</th>" for h in c["table_head"])
    body_rows = "\n".join(
        "      <tr>" + "".join(f"<td>{cell}</td>" for cell in row) + "</tr>"
        for row in c["table_rows"])
    table = (f'  <table>\n    <thead>\n      <tr>{head_cells}</tr>\n    </thead>\n'
             f'    <tbody>\n{body_rows}\n    </tbody>\n  </table>')

    # Every language of this page links to every other, so a reader who lands on
    # the wrong one is one tap away rather than back at the site root.
    alternates = "\n".join(
        f'<link rel="alternate" hreflang="{LANGS[l][1]}" href="{site}/{LANGS[l][0]}sync.html">'
        for l in LANGS)
    alternates += f'\n<link rel="alternate" hreflang="x-default" href="{site}/sync.html">'
    switcher = " ".join(
        f'<a href="{site}/{LANGS[l][0]}sync.html">{CONTENT[l]["lang_label"]}</a>'
        if l != lang else f'<span>{CONTENT[l]["lang_label"]}</span>'
        for l in LANGS)

    blocks = [
        f'  <p class="updated">{c["updated"]}</p>',
        f'  <p class="langs">{switcher}</p>',
        f'  <h1>{c["h1"]}</h1>',
        p(c["intro"]),
        table,
        p(c["both"]),
        f'  <h2 id="icloud">{c["icloud_h"]}</h2>',
        p(c["icloud_1"]), p(c["icloud_2"]), box(c["icloud_box"]),
        f'  <h2 id="github">{c["github_h"]}</h2>',
        p(c["github_1"]),
        figure(SHOTS["settings"], c["shot_settings"], up),
        f'  <h3>{c["first_h"]}</h3>',
        items("ol", c["first_steps"]),
        f'  <h3>{c["second_h"]}</h3>',
        p(c["second_lede"]),
        items("ol", c["second_steps"]),
        p(c["second_why"]),
        box(c["binding_box"]),
        f'  <h2 id="conflicts">{c["conflict_h"]}</h2>',
        p(c["conflict_lede"]), box(c["conflict_rule"]), p(c["conflict_1"]),
        p(c["conflict_which"]), items("ul", c["conflict_points"]), p(c["conflict_2"]),
        figure(SHOTS["conflict"], c["shot_conflict"], up, kind="narrow"),
        f'  <h3>{c["first_sync_h"]}</h3>', p(c["first_sync_p"]),
        f'  <h3>{c["fewer_h"]}</h3>', items("ul", c["fewer_points"]),
        f'  <h2 id="schedule">{c["often_h"]}</h2>',
        p(c["often_1"]), p(c["often_2"]), p(c["often_3"]),
        f'  <h2 id="git">{c["git_h"]}</h2>',
        p(c["git_1"]),
        figure(SHOTS["git"], c["shot_git"], up),
        p(c["git_2"]), p(c["git_3"]),
        diagram(*c["diagram"]),
        p(c["git_4"]), p(c["git_5"]),
        f'  <h2 id="refuses">{c["refuse_h"]}</h2>',
        p(c["refuse_lede"]), items("ul", c["refuse_points"]), p(c["refuse_tail"]),
        f'  <h2 id="files">{c["files_h"]}</h2>',
        p(c["files_1"]), p(c["files_2"]),
        f'  <a class="home" href="{site}/{prefix}">{c["home"]}</a>',
    ]

    return f"""<!doctype html>
<html lang="{hreflang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{c["title"]}</title>
<meta name="description" content="{c["description"]}">
<link rel="canonical" href="{site}/{prefix}sync.html">
{alternates}
<link rel="icon" href="{up}assets/icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&display=swap">
<link rel="stylesheet" href="{up}assets/styles.css?v={asset_hash("assets/styles.css")}">
<style>{STYLE}</style>
</head>
<body>
<main class="wrap doc" id="main">
{chr(10).join(blocks)}
</main>
</body>
</html>
"""
