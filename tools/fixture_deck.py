"""CARBON M0: generate the fixture slide deck and its ground truth from one source.

Writes:
  tools/fixture-deck/index.html             the deck (open in a browser, full screen, arrow keys)
  ios/CarbonTests/Fixtures/slides/slideNN.txt   exact text of each slide, in reading order
  ios/Carbon/Resources/Fixtures/slideNN.txt     the same, bundled for the app's on-device fixture check

Run from the repo root:  python tools/fixture_deck.py
Standard library only. Edit SLIDES below, then re-run; never edit the outputs by hand.
"""

from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DECK = ROOT / "tools" / "fixture-deck" / "index.html"
TRUTH_DIR = ROOT / "ios" / "CarbonTests" / "Fixtures" / "slides"
APP_TRUTH_DIR = ROOT / "ios" / "Carbon" / "Resources" / "Fixtures"

# Each slide: a theme and a list of blocks, top to bottom.
# Block kinds: title, subtitle, meta, bullets, numbered, paragraph, table, code, lines, caption, footer.
SLIDES = [
    {   # 1: large text, plus the lines Clean mode (M4) will treat as junk
        "theme": "light",
        "blocks": [
            ("spacer", None),
            ("title-xl", "Week 6: Usability Testing"),
            ("subtitle", "Planning, running, and analyzing small studies"),
            ("spacer", None),
            ("meta", "CMSC 434 · Fall 2026 · October 9, 2026"),
        ],
    },
    {   # 2: the typical bullet slide
        "theme": "light",
        "blocks": [
            ("title", "Why test with users?"),
            ("bullets", [
                "Designers are not typical users",
                "Five participants find most major problems",
                "Testing early is cheaper than fixing late",
                "Watch what people do, not what they say",
                "Iterate: test, fix, and test again",
            ]),
        ],
    },
    {   # 3: dense paragraph in a small font
        "theme": "light",
        "blocks": [
            ("title", "Think-aloud protocol"),
            ("paragraph-small",
             "In a think-aloud session, the participant narrates their thoughts while completing "
             "realistic tasks. The facilitator stays neutral, avoids leading questions, and only "
             "prompts with short phrases such as \"What are you thinking now?\" Sessions are usually "
             "recorded with screen capture and audio, so the team can review hesitations, errors, and "
             "workarounds later. Concurrent think-aloud can slow participants down, so task times "
             "collected this way should not be compared directly with silent sessions. Retrospective "
             "think-aloud avoids this cost but relies on memory, which is less reliable after long tasks."),
        ],
    },
    {   # 4: numbered list with lettered sub-items
        "theme": "light",
        "blocks": [
            ("title", "Running a session"),
            ("numbered", [
                ("1.", "Welcome the participant and get consent", 0),
                ("2.", "Explain the think-aloud method", 0),
                ("3.", "Give one task at a time:", 0),
                ("a)", "Read the task aloud", 1),
                ("b)", "Start the timer", 1),
                ("c)", "Note errors and hesitations", 1),
                ("4.", "Finish with a short questionnaire", 0),
                ("5.", "Thank and compensate the participant", 0),
            ]),
        ],
    },
    {   # 5: a table, read row by row
        "theme": "light",
        "blocks": [
            ("title", "Task success by round"),
            ("table", [
                ["Task", "Round 1", "Round 2", "Change"],
                ["Find a course", "3/5", "5/5", "+40%"],
                ["Add to cart", "2/5", "4/5", "+40%"],
                ["Check out", "1/5", "4/5", "+60%"],
                ["Edit profile", "4/5", "5/5", "+20%"],
            ]),
        ],
    },
    {   # 6: code, punctuation-heavy
        "theme": "light",
        "blocks": [
            ("title", "Logging task events (Swift)"),
            ("code", [
                "struct TaskEvent: Codable {",
                "    let id: UUID",
                "    let name: String",
                "    let startedAt: Date",
                "    var errors = 0",
                "}",
                "",
                "func log(_ e: TaskEvent) {",
                "    print(\"[\\(e.name)] errors=\\(e.errors)\")",
                "}",
            ]),
        ],
    },
    {   # 7: numbers and symbols
        "theme": "light",
        "blocks": [
            ("title", "Measuring efficiency"),
            ("lines", [
                "Mean task time: 74.2 s (SD = 18.6 s)",
                "Error rate = errors / attempts = 12 / 40 = 30%",
                "SUS score: 68 is about average; 80.3 or higher is excellent",
                "Completion target: ≥ 90% within 2 min",
                "p < 0.05 with n = 12 per group",
            ]),
        ],
    },
    {   # 8: bullets plus a small low-contrast caption
        "theme": "light",
        "blocks": [
            ("title", "Reporting findings"),
            ("bullets", [
                "Lead with the three most severe problems",
                "Show a short clip for each problem",
                "Pair every problem with a concrete fix",
                "Keep the full list in an appendix",
            ]),
            ("caption", "Source: adapted from course notes, Week 6. Severity uses a 0-4 scale."),
        ],
    },
    {   # 9: footer and edge text (M4 Clean mode drops these later; As-is keeps them)
        "theme": "light",
        "blocks": [
            ("title", "Severity ratings"),
            ("lines", [
                "0: Not a usability problem",
                "1: Cosmetic, fix if time allows",
                "2: Minor, low priority",
                "3: Major, high priority",
                "4: Catastrophe, must fix before release",
            ]),
            ("footer", ["CMSC 434 Fall 2026", "https://cs.example.edu/434", "Slide 9 / 10"]),
        ],
    },
    {   # 10: dark, projector-style theme
        "theme": "dark",
        "blocks": [
            ("title", "Next steps"),
            ("bullets", [
                "Fix the three major issues from round 2",
                "Recruit five new participants",
                "Run round 3 on Thursday at 2:30 pm",
                "Share the report in the team channel",
            ]),
        ],
    },
]

BULLET = "•"


def truth_lines(slide):
    """The slide's text in reading order: top to bottom, each row left to right."""
    lines = []
    for kind, value in slide["blocks"]:
        if kind == "spacer":
            continue
        if kind in ("bullets",):
            lines += [f"{BULLET} {item}" for item in value]
        elif kind == "numbered":
            lines += [f"{marker} {text}" for marker, text, _ in value]
        elif kind == "table":
            lines += [" ".join(row) for row in value]
        elif kind in ("code", "lines"):
            lines += [line for line in value if line.strip()]
        elif kind == "footer":
            lines.append(" ".join(value))
        else:
            lines.append(value)
    return lines


def block_html(kind, value):
    if kind == "spacer":
        return '<div class="spacer"></div>'
    if kind == "bullets":
        items = "".join(f'<li><span class="mark">{BULLET}</span>{escape(t)}</li>' for t in value)
        return f'<ul class="bullets">{items}</ul>'
    if kind == "numbered":
        items = "".join(
            f'<li class="level{level}"><span class="mark">{escape(m)}</span>{escape(t)}</li>'
            for m, t, level in value)
        return f'<ul class="numbered">{items}</ul>'
    if kind == "table":
        head = "".join(f"<th>{escape(c)}</th>" for c in value[0])
        rows = "".join("<tr>" + "".join(f"<td>{escape(c)}</td>" for c in r) + "</tr>" for r in value[1:])
        return f"<table><thead><tr>{head}</tr></thead><tbody>{rows}</tbody></table>"
    if kind == "code":
        return f'<pre class="code">{escape(chr(10).join(value))}</pre>'
    if kind == "lines":
        return '<div class="lines">' + "".join(f"<p>{escape(t)}</p>" for t in value) + "</div>"
    if kind == "footer":
        return '<div class="footer">' + "".join(f"<span>{escape(t)}</span>" for t in value) + "</div>"
    tag = {"title-xl": "h1", "title": "h2"}.get(kind, "p")
    return f'<{tag} class="{kind}">{escape(value)}</{tag}>'


def deck_html():
    sections = [
        '<section class="slide light" data-n="0"><div class="stage intro">'
        "<h2>CARBON fixture deck</h2>"
        "<p>Ten test slides for the M0 capture benchmark.</p>"
        "<p>Press F11 for full screen. Right arrow or Space for the next slide, Left arrow to go back, "
        "Home for this page. The address bar shows the slide number after #.</p>"
        "<p>This page is not a fixture. Start capturing at slide 1.</p>"
        "</div></section>"
    ]
    for n, slide in enumerate(SLIDES, start=1):
        body = "".join(block_html(kind, value) for kind, value in slide["blocks"])
        sections.append(f'<section class="slide {slide["theme"]}" data-n="{n}"><div class="stage">{body}</div></section>')
    return TEMPLATE.replace("{{SLIDES}}", "\n".join(sections)).replace("{{COUNT}}", str(len(SLIDES)))


TEMPLATE = """<!doctype html>
<!-- Generated by tools/fixture_deck.py. Do not edit by hand. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CARBON fixture deck</title>
<style>
  html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
  .slide { display: none; position: fixed; inset: 0; align-items: center; justify-content: center; }
  .slide.active { display: flex; }
  /* A 16:9 stage that fills the screen; all sizes scale with its width. */
  .stage { --w: min(100vw, 177.78vh); width: var(--w); height: calc(var(--w) * 0.5625);
           box-sizing: border-box; padding: calc(var(--w) * 0.05) calc(var(--w) * 0.06);
           font-family: Arial, Helvetica, sans-serif; position: relative;
           display: flex; flex-direction: column; }
  .light .stage { background: #ffffff; color: #111111; }
  .dark .stage { background: #14213d; color: #f5f5f5; }
  h1, h2, p, ul, table, pre { margin: 0; }
  .title-xl { font-size: calc(var(--w) * 0.055); font-weight: 700; text-align: center; }
  .subtitle { font-size: calc(var(--w) * 0.026); text-align: center; margin-top: calc(var(--w) * 0.015); color: #333; }
  .meta { font-size: calc(var(--w) * 0.018); text-align: center; color: #444; }
  .spacer { flex: 1; }
  .title { font-size: calc(var(--w) * 0.040); font-weight: 700; margin-bottom: calc(var(--w) * 0.025); }
  .bullets, .numbered { list-style: none; padding: 0; font-size: calc(var(--w) * 0.024); line-height: 1.45; }
  .mark { display: inline-block; min-width: 1.4em; }
  .numbered .level1 { padding-left: 2.2em; }
  .paragraph-small { font-size: calc(var(--w) * 0.0165); line-height: 1.5; }
  table { border-collapse: collapse; font-size: calc(var(--w) * 0.022); }
  th, td { text-align: left; padding: 0.35em 1.4em 0.35em 0; border-bottom: 2px solid #ccc; }
  th { font-weight: 700; }
  .code { font-family: Consolas, "Courier New", monospace; font-size: calc(var(--w) * 0.019);
          line-height: 1.4; background: #f3f3f3; padding: 0.8em 1em; border-radius: 6px; }
  .lines p { font-size: calc(var(--w) * 0.023); line-height: 1.55; }
  .caption { margin-top: auto; font-size: calc(var(--w) * 0.012); color: #8a8a8a; }
  .footer { margin-top: auto; display: flex; justify-content: space-between;
            font-size: calc(var(--w) * 0.011); color: #666; }
  .intro p { font-size: calc(var(--w) * 0.018); line-height: 1.5; margin-top: 1em; color: #333; }
</style>
</head>
<body>
{{SLIDES}}
<script>
  const slides = [...document.querySelectorAll('.slide')];
  const last = {{COUNT}};
  function show(n) {
    n = Math.max(0, Math.min(last, n));
    slides.forEach(s => s.classList.toggle('active', Number(s.dataset.n) === n));
    history.replaceState(null, '', '#' + n);
  }
  function current() { return Number(location.hash.slice(1)) || 0; }
  document.addEventListener('keydown', e => {
    if (['ArrowRight', ' ', 'PageDown', 'Enter'].includes(e.key)) show(current() + 1);
    else if (['ArrowLeft', 'PageUp', 'Backspace'].includes(e.key)) show(current() - 1);
    else if (e.key === 'Home') show(0);
    else return;
    e.preventDefault();
  });
  document.addEventListener('click', () => show(current() + 1));
  window.addEventListener('hashchange', () => show(current()));
  show(current());
</script>
</body>
</html>
"""


def main():
    DECK.parent.mkdir(parents=True, exist_ok=True)
    DECK.write_text(deck_html(), encoding="utf-8", newline="\n")
    for folder in (TRUTH_DIR, APP_TRUTH_DIR):
        folder.mkdir(parents=True, exist_ok=True)
        for n, slide in enumerate(SLIDES, start=1):
            path = folder / f"slide{n:02d}.txt"
            path.write_text("\n".join(truth_lines(slide)) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {DECK.relative_to(ROOT)} and {len(SLIDES)} truth files in "
          f"{TRUTH_DIR.relative_to(ROOT)} and {APP_TRUTH_DIR.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
