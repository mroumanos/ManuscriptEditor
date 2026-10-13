#!/usr/bin/env python3
"""Builds the JAMA Network journal profiles from the specs in `jama/`.

One spec file per journal (JAMA, JAMA Cardiology, …), each listing the
journal's article types with the limits its Instructions for Authors state —
and, for every number, the page's own sentence in `quotes`.  This script turns
each article type into one profile folder under
`ManuscriptEditor/JournalProfiles/<slug>/` with the three files the app reads
(`requirements.json`, `checks.json`, `structure.json`).

The specs are the source; the profiles are what ships.  Edit a spec and
re-run — never hand-edit a generated profile, the next run would undo it.

    scripts/corpus/build_jama.py            # write every profile
    scripts/corpus/build_jama.py --check    # exit 1 if a profile is stale

A spec is written two ways: by hand, in this script's terms (an abstract
layout by name, sections as titles), or as extracted from a page (headings
listed, sections with the page's own budgets in parentheses, requirements in
the page's words).  `normalize` reads both.

Identity follows the app's rule: the GUID is derived from the slug
(`JournalProfile.bundledID`), so every install agrees on it without a
registry.  The derivation is reproduced here and checked against a shipped
profile on every run.
"""
import hashlib
import json
import re
import shutil
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPECS = HERE / "jama"
OUT = ROOT / "ManuscriptEditor" / "JournalProfiles"
STAMP = "2026-10-13T12:00:00Z"

PUBLISHER = "American Medical Association"
COUNTRY = "United States"

# ── Network-wide rules (the same on every JAMA Network instructions page) ──

# The needles a structured abstract is checked for (CONTAINS, case-insensitive);
# a list inside the list is "either of these".
ABSTRACT_HEADINGS = {
    "original": ["Importance", "Objective", "Design", "Setting", "Participants",
                 ["Intervention", "Exposure"], "Main Outcome", "Results", "Conclusions and Relevance"],
    "trial": ["Importance", "Objective", "Design", "Setting", "Participants",
              ["Intervention", "Exposure"], "Main Outcome", "Results", "Conclusions and Relevance",
              "Trial Registration"],
    "metaAnalysis": ["Importance", "Objective", "Data Sources", "Study Selection",
                     "Data Extraction and Synthesis", "Main Outcome", "Results", "Conclusions and Relevance"],
    "systematicReview": ["Importance", "Objective", "Evidence Review", "Findings", "Conclusions and Relevance"],
    "narrativeReview": ["Importance", "Observations", "Conclusions and Relevance"],
}
# The venue's full heading labels — what the boilerplate and the summary say.
# Design, Setting and Participants are kept as separate headings at
# submission (combined only at acceptance).
ABSTRACT_LABELS = {
    "original": ["Importance", "Objective", "Design", "Setting", "Participants", "Intervention(s) or Exposure(s)",
                 "Main Outcome(s) and Measure(s)", "Results", "Conclusions and Relevance"],
    "trial": ["Importance", "Objective", "Design", "Setting", "Participants", "Intervention(s)",
              "Main Outcome(s) and Measure(s)", "Results", "Conclusions and Relevance", "Trial Registration"],
    "metaAnalysis": ["Importance", "Objective", "Data Sources", "Study Selection", "Data Extraction and Synthesis",
                     "Main Outcome(s) and Measure(s)", "Results", "Conclusions and Relevance"],
    "systematicReview": ["Importance", "Objective", "Evidence Review", "Findings", "Conclusions and Relevance"],
    "narrativeReview": ["Importance", "Observations", "Conclusions and Relevance"],
}
KEY_POINTS_WORDS = 100
IMRAD = ["Introduction", "Methods", "Results", "Discussion"]

COVER_LETTER = ("complete contact information for the corresponding author and whether the authors have "
                "published, posted, or submitted any related papers from the same study")
FORMAT_BULLETS = [
    "format: submit a Word document (not PDF); 10-, 11-, or 12-point font, double-spaced, right margins unjustified (ragged).",
    "format: title page, abstract, text, references, figure legends and tables each start on a new page, numbered consecutively from the title page.",
    "format: title page carries the title, every author's full name, highest academic degrees and affiliations, the corresponding author's complete contact information, and the manuscript word count (not including title, abstract, acknowledgment, references, tables, and figure legends).",
    "format: AMA Manual of Style, 11th edition — references numbered in order of first citation, cited with superscript Arabic numerals; up to 6 authors listed, otherwise the first 3 and et al.; journal names abbreviated per PubMed.",
    "format: tables at the end of the manuscript file, numbered in citation order, titles of 10–15 words, 10- or 12-point single-spaced, never as images.",
    "format: each figure a separate file of at most 1 MB; photographs and illustrations at least 350 ppi, line drawings at least 600 ppi; no pie charts, 3-D graphs or stacked bar charts; avoid more than 4 panels.",
    "format: individual files should stay under 500 kB and must not exceed 1 MB; the whole submission under 5 MB (video excluded).",
]
ACKNOWLEDGMENT_BULLET = ("components: Acknowledgment section — author contributions; a data access statement by 1 or 2 named "
                         "authors who had full access to all the data; conflict of interest disclosures for every author; "
                         "funding and the funder's role; any AI tool used, with name, version, manufacturer and how it was used.")
METHODS_NOTE = ("State ethics approval (or its waiver) and informed consent; name the statistical software with its version "
                "and manufacturer at the end.")
DISCUSSION_NOTE = "Place the results in context with the published literature and address the study's limitations."
DISCLAIMER = "extra: this summary is the app's distillation — open the author instructions above to confirm against the journal's current text."

# A requirement the page states → the manual test it becomes.  Matched by
# key (case-insensitive) against the spec's phrase, plus the aliases below.
REQUIREMENT_CHECKS = {
    "Data Sharing Statement": ("Data Sharing Statement supplied", "Says whether the data will be shared and, if so, what, when, where and how; published as an online supplement."),
    "EQUATOR": ("Reporting guideline followed and checklist attached", "The EQUATOR guideline for the study design (CONSORT, STROBE, PRISMA, STARD, …), named in the Methods."),
    "CONSORT": ("CONSORT: flow diagram, checklist, and the Methods say how the report follows it", "The flow diagram counts toward the tables and figures."),
    "PRISMA": ("PRISMA (or MOOSE) followed; flow diagram in the online supplement", None),
    "trial registration": ("Trial registered; registry name, ID and URL end the abstract", "Registration in a public clinical trial registry before enrollment."),
    "trial protocol": ("Original trial protocol with the statistical analysis plan and amendments attached", None),
    "evidence quality table": ("A table rates the quality of the studies and evidence", None),
    "within 4 weeks": ("Submitted within 4 weeks of the article it responds to", None),
}
REQUIREMENT_ALIASES = {
    "EQUATOR": ["reporting guideline"],
    "trial registration": ["registered", "registration"],
    "trial protocol": ["protocol"],
    "evidence quality table": ["quality of the studies", "quality of the evidence"],
    "PRISMA": ["moose"],
}
# Page phrases that restate a limit the generator already tests — not a test.
REQUIREMENT_RESTATEMENTS = ("structured abstract", "3-part structured abstract", "a list of 3 key points",
                            "no abstract", "no key points", "key points", "study type", "title limited")

# Page names for a type that fold into the profile's name.
TYPE_RENAMES = {
    "Clinical Trial (Randomized or Nonrandomized; Original Investigation)": "Clinical Trial",
    "Meta-analysis (Original Investigation)": "Meta-analysis",
    "Narrative Review (Review)": "Narrative Review",
}
# Page entries that duplicate a profile: the Original Investigation covers
# every observational design.
TYPE_DROPS = ("Other Observational Stud", "Original Investigation: Other Study Designs",
              "Poetry")    # 44 lines of 55 characters is not a manuscript this app writes


def is_dropped(t):
    """Page entries that are not a profile: a grouping the Original
    Investigation already covers, or a type the page names without a single
    limit (commissioned features such as an Invited Commentary)."""
    if t["name"].startswith(TYPE_DROPS):
        return True
    return not any(t.get(k) for k in ("words", "referencesMax", "tablesFiguresCombined", "figuresMax",
                                      "tablesMax", "authorsMax", "sections", "abstractWords"))
# The page's section names, read from their first words, to the title a
# manuscript section gets.
SECTION_TITLES = [
    ("5 bulleted summary points", "Summary Points"),
    ("discussion and patient course", "Discussion and Patient Course"),
    ("case presentation", "Case Presentation"),
    ("diagnosis and discussion", "Diagnosis and Discussion"),
    ("methods/literature search", "Methods"),
    ("methods", "Methods"),
    ("discussion/observations", "Discussion"),
    ("question", "Question"),
    ("test characteristics", "Test Characteristics"),
    ("application of test result", "Application of Test Result to This Patient"),
    ("alternative diagnostic testing", "Alternative Diagnostic Testing Approaches"),
    ("patient outcome", "Patient Outcome"),
    ("clinical bottom line", "Clinical Bottom Line"),
]


def slugify(name, article_type):
    joined = "-".join(x for x in (name, article_type) if x)
    out = "".join(ch if ch.isalnum() else "-" for ch in joined.lower())
    return "-".join(p for p in out.split("-") if p)


def bundled_id(slug):
    b = bytearray(hashlib.sha256(slug.encode()).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(b))).upper()


assert bundled_id("american-journal-of-public-health-research-article") == "7326FAF0-32D6-5C37-B991-452D852CEFEB", \
    "the GUID derivation no longer matches the app's"


def unquote(s):
    s = (s or "").strip()
    while len(s) > 1 and s[0] in "'\"‘“" and s[-1] in "'\"’”":
        s = s[1:-1].strip()
    return s


# ── Normalising a spec ──

def abstract_layout(t):
    """The named layout a listed set of headings is, or the list itself."""
    h = t.get("abstractHeadings")
    if not isinstance(h, list):
        return h
    low = [x.lower() for x in h]
    if any("data sources" in x for x in low):
        return "metaAnalysis"
    if any("evidence review" in x for x in low):
        return "systematicReview"
    if any("observations" in x for x in low):
        return "narrativeReview"
    if any("importance" in x for x in low) and any("design" in x for x in low):
        return "trial" if "trial" in t["name"].lower() else "original"
    return h


def subtitles(value):
    """The study-type phrase(s) a subtitle must carry, from a hand list, one
    phrase, or the page's sentence quoting them."""
    if not value:
        return None
    if isinstance(value, list):
        return value
    low = value.lower()
    if "clinical trials, meta-analyses, and systematic reviews" in low or "do not include" in low:
        return None     # the page's general rule, not a requirement of this type
    quoted = [q for q in re.findall(r"[\'‘“]([^\'’”]+)[\'’”]", value) if q.startswith("A ")]
    if quoted:
        return quoted
    return [value] if value.startswith("A ") else None


def section_entry(raw):
    """A section as the page names it ("Methods (optional; 150-250 words)")
    → the title a manuscript section gets, with the page's words as its
    note."""
    if isinstance(raw, dict):
        return raw
    raw = raw.replace("(s)", "s")
    m = re.match(r"^(.*?)\s*\(([^)]*)\)\s*(.*)$", raw)
    head, paren = (m.group(1), m.group(2) + ("; " + m.group(3) if m.group(3) else "")) if m else (raw, None)
    title = head.strip().rstrip(":")
    for prefix, canonical in SECTION_TITLES:
        if title.lower().startswith(prefix):
            title = canonical
            break
    else:
        title = title_case(title)
    entry = {"title": title, "required": not (paren and "optional" in paren.lower())}
    if paren:
        note = paren if len(head.strip()) <= len(title) + 3 else raw.rstrip(".")
        entry["note"] = note[0].upper() + note[1:]
    elif len(head.strip()) > len(title) + 3:
        entry["note"] = raw.rstrip(".")
    return entry


SMALL_WORDS = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "with"}


def title_case(s):
    words = s.split()
    return " ".join(w if (i and w.lower() in SMALL_WORDS) or w[:1].isupper() else w[:1].upper() + w[1:]
                    for i, w in enumerate(words))


def single_section_name(name):
    if name.startswith("Letter in Reply"):
        return "Reply"
    if name.startswith("Letter to the Editor"):
        return "Letter"
    return re.sub(r"\s*\(.*\)$", "", name)


def cover_letter(j):
    """"required", "recommended" (JAMA Network Open), or None."""
    text = (j.get("formatting") or {}).get("coverLetter")
    if not text:
        return None
    return "recommended" if "recommend" in text.lower() else "required"


def normalize(t):
    t = dict(t)
    t["name"] = TYPE_RENAMES.get(t["name"], t["name"])
    t["abstractHeadings"] = abstract_layout(t)
    t["subtitle"] = subtitles(t.get("subtitle"))
    t["keyPoints"] = bool(t.get("keyPoints"))
    if t.get("abstract") is None and not t["keyPoints"] and (t.get("words") or 0) < 2000 \
            and not t.get("abstractWords"):
        # "Abstracts are not required for Editorials, Viewpoints, and special
        # features" — the page lists these short types without one.
        t["abstract"] = "none"
    t["wordsNote"] = unquote(t.get("wordsNote"))
    if t.get("figuresMax") and t.get("tablesFiguresCombined") and not t.get("tablesMax") \
            and t["figuresMax"] >= t["tablesFiguresCombined"]:
        t["figuresMax"] = None      # the combined limit already says it
    t["description"] = unquote(t.get("description"))
    if t.get("titleChars") is None:
        # "100 characters for research reports and major articles; 60 for
        # shorter article types such as opinion articles and Letters."
        t["titleChars"] = 60 if t.get("abstract") == "none" else 100

    sections = t.get("sections")
    if sections == "imrad":
        sections = IMRAD
    elif sections is None:
        research = t["abstractHeadings"] in ("original", "trial", "metaAnalysis") \
            or t["name"] in ("Brief Report", "Research Letter")
        sections = IMRAD if research else [{"title": single_section_name(t["name"]),
                                             "note": "The venue names no sections for this article type."}]
    # A page may list the abstract and the Key Points among the sections;
    # those entries are built from the type's own fields, not from that line.
    t["sections"] = [e for e in (section_entry(s) for s in sections)
                     if e["title"].lower() not in ("abstract", "key points")]

    mapped, notes = [], list(t.get("notes") or [])
    for req in t.get("requirements") or []:
        low = req.lower()
        if "presubmission" in low:
            t["presubmissionInquiry"] = True
            continue
        if "permission" in low:
            t["patientPermission"] = True
            continue
        for key, (_, _) in REQUIREMENT_CHECKS.items():
            if key.lower() in low or any(a in low for a in REQUIREMENT_ALIASES.get(key, [])):
                mapped.append(key)
                break
        else:
            if not low.startswith(REQUIREMENT_RESTATEMENTS):
                notes.append(req)
    seen = set()
    t["requirements"] = [r for r in mapped if not (r in seen or seen.add(r))]
    t["notes"] = [unquote(n) for n in notes]
    return t


# ── Check-rule builders ──

def cond(metric, scopes, comparator=None, number=None, text=None):
    c = {"metric": metric, "scopes": scopes}
    if comparator is not None:
        c["comparator"] = comparator
        c["number"] = number
    if text is not None:
        c["text"] = text
    return c


def rule(name, conditions, note=None, combinator="ALL"):
    r = {"combinator": combinator, "conditions": conditions, "name": name}
    if note:
        r["note"] = note
    return r


def manual(name, note=None):
    return {"conditions": [], "manual": True, "name": name, "note": note or "Tick once verified by hand"}


def scope(kind, name=None):
    return {"kind": kind, "name": name} if name else {"kind": kind}


def fmt(n):
    return f"{n:,}"


def layout_text(key):
    return "; ".join(ABSTRACT_LABELS[key]) if key in ABSTRACT_LABELS else "; ".join(key)


def heading_rules(key):
    """One ALL rule over the headings a structured abstract must carry, plus an
    ANY rule for each heading the venue words two ways."""
    headings = ABSTRACT_HEADINGS[key] if key in ABSTRACT_HEADINGS else key
    rules = [rule("Structured abstract headings",
                  [cond("CONTAINS", [scope("abstract")], text=h) for h in headings if isinstance(h, str)],
                  note=layout_text(key))]
    for alternatives in (h for h in headings if isinstance(h, list)):
        rules.append(rule("Abstract names the " + " or ".join(a.lower() for a in alternatives),
                          [cond("CONTAINS", [scope("abstract")], text=a) for a in alternatives],
                          combinator="ANY"))
    return rules


def build_checks(j, t):
    checks = []
    words = t.get("words")
    if words:
        note = "Not including abstract, tables, figures, acknowledgments, references, and online-only material."
        wn = t.get("wordsNote")
        if wn and wn not in ("of text", "total") and not wn.lower().startswith("not including"):
            note = wn[0].upper() + wn[1:].rstrip(".") + "."
        elif wn and wn.lower().startswith("not including"):
            note = wn[0].upper() + wn[1:].rstrip(".") + "."
        if t.get("keyPoints"):
            note += " Counts every active section, Key Points included; the venue counts those separately."
        name = f"Body ≤ {fmt(words)} words" + (" (recommended)" if t.get("wordsIsRecommended") else "")
        checks.append(rule(name, [cond("LENGTH_WORDS", [scope("body")], "<=", words)], note=note))

    abstract = t.get("abstract")
    if abstract == "none":
        checks.append(rule("No abstract", [cond("LENGTH_WORDS", [scope("abstract")], "<=", 0)],
                           note="This article type carries no abstract — leave the Abstract empty or deactivate it."))
    elif t.get("abstractWords"):
        checks.append(rule(f"Abstract ≤ {t['abstractWords']} words",
                           [cond("LENGTH_WORDS", [scope("abstract")], "<=", t["abstractWords"])]))
    if abstract == "structured" and t.get("abstractHeadings"):
        checks += heading_rules(t["abstractHeadings"])

    if t.get("keyPoints"):
        kp = scope("section", "Key Points")
        checks.append(rule(f"Key Points ≤ {KEY_POINTS_WORDS} words",
                           [cond("LENGTH_WORDS", [kp], "<=", KEY_POINTS_WORDS)],
                           note="Question (1 sentence), Findings (1–2 sentences, design and primary outcomes, significance without test statistics), Meaning (1 sentence)."))
        checks.append(rule("Key Points: Question, Findings, Meaning",
                           [cond("CONTAINS", [kp], text=x) for x in ("Question", "Findings", "Meaning")]))

    if t.get("referencesMax"):
        checks.append(rule(f"References ≤ {t['referencesMax']}",
                           [cond("COUNT", [scope("references")], "<=", t["referencesMax"])],
                           note=f"The venue expects {t['referencesMin']}–{t['referencesMax']}." if t.get("referencesMin") else None))
    if t.get("tablesFiguresCombined"):
        checks.append(rule(f"Tables + figures ≤ {t['tablesFiguresCombined']}",
                           [cond("COUNT", [scope("figures"), scope("tables")], "<=", t["tablesFiguresCombined"])]))
    if t.get("figuresMax"):
        checks.append(rule(f"Figures ≤ {t['figuresMax']}", [cond("COUNT", [scope("figures")], "<=", t["figuresMax"])]))
    if t.get("tablesMax"):
        checks.append(rule(f"Tables ≤ {t['tablesMax']}", [cond("COUNT", [scope("tables")], "<=", t["tablesMax"])]))
    if t.get("authorsMax"):
        checks.append(rule(f"Authors ≤ {t['authorsMax']}", [cond("COUNT", [scope("authors")], "<=", t["authorsMax"])]))

    title_chars = t["titleChars"]
    checks.append(rule(f"Title ≤ {title_chars} characters",
                       [cond("LENGTH_CHARS", [scope("title")], "<=", title_chars)],
                       note="Including spaces. Research reports and major articles 100; shorter article types 60."))
    if t.get("subtitle"):
        checks.append(rule("Subtitle names the study type",
                           [cond("CONTAINS", [scope("subtitle")], text=s) for s in t["subtitle"]],
                           note="Expected: " + " or ".join(f"“{s}”" for s in t["subtitle"]),
                           combinator="ANY"))

    checks.append(rule("Export font 10–12 pt",
                       [cond("FONT_SIZE", [scope("export")], ">=", 10.0),
                        cond("FONT_SIZE", [scope("export")], "<=", 12.0)]))
    checks.append(rule("Export double-spaced", [cond("LINE_SPACING", [scope("export")], ">=", 2.0)]))

    checks.append(rule("Sections match the journal's structure",
                       [cond("STRUCTURE", [], "==", 1)],
                       note="Every section marked required in the structure file must be present and non-empty"))

    if cover_letter(j) == "required":
        checks.append(rule("Cover letter present", [cond("EXISTS", [scope("coverLetter")], "<=", 0)],
                           note=COVER_LETTER[0].upper() + COVER_LETTER[1:] + "."))

    for key in t["requirements"]:
        name, note = REQUIREMENT_CHECKS[key]
        checks.append(manual(name, note))
    if t.get("presubmissionInquiry"):
        checks.append(manual("Presubmission inquiry sent and encouraged by the editors",
                             "This article type requires a presubmission inquiry."))
    if t.get("patientPermission"):
        checks.append(manual("Patient permission form signed and submitted",
                             "The JAMA Network Patient Permission form, for any identifiable patient."))
    if abstract and abstract != "none":
        checks.append(manual("Acknowledgment complete: contributions, data access statement, disclosures, funding and its role"))
    checks.append(manual("Conflict of interest disclosures for every author",
                         "Complete disclosure of all relevant financial relationships; authors with none say so."))

    for s in t["sections"]:
        if s.get("required", True):
            checks.append(rule(f"{s['title']} section present",
                               [cond("EXISTS", [scope("section", s["title"])], "<=", 0)],
                               note="Required by this journal's structure."))
    return checks


# ── Structure ──

def build_structure(j, t):
    sections = []
    if t.get("keyPoints"):
        sections.append({
            "title": "Key Points", "required": True,
            "formatNote": f"Three labelled parts before the abstract, {KEY_POINTS_WORDS} words or fewer in all: Question (1 sentence), Findings (1–2 sentences — the design and primary outcomes, significance stated without statistical test results), Meaning (1 sentence).",
            "note": "The venue's structured summary of the study, read before the abstract.",
            "boilerplate": "Question: \nFindings: \nMeaning: ",
        })
    abstract = t.get("abstract")
    if abstract == "none":
        sections.append({"title": "Abstract", "required": False,
                         "note": "This article type has no abstract."})
    elif abstract == "structured":
        key = t.get("abstractHeadings")
        entry = {"title": "Abstract", "required": True}
        words = f"no more than {t['abstractWords']} words" if t.get("abstractWords") else None
        if key:
            labels = ABSTRACT_LABELS[key] if key in ABSTRACT_LABELS else key
            entry["formatNote"] = "Structured" + (f", {words}" if words else "") + ", under the headings " + "; ".join(labels) + "."
            entry["boilerplate"] = "\n".join(label + ": " for label in labels)
        else:
            entry["formatNote"] = "Structured" + (f", {words}" if words else "") + "; the venue does not fix the headings for this type."
        sections.append(entry)
    elif abstract == "unstructured":
        entry = {"title": "Abstract", "required": True}
        if t.get("abstractWords"):
            entry["formatNote"] = f"Unstructured, no more than {t['abstractWords']} words."
        sections.append(entry)

    notes = {"Methods": METHODS_NOTE, "Discussion": DISCUSSION_NOTE}
    for s in t["sections"]:
        entry = {"title": s["title"], "required": s.get("required", True)}
        note = s.get("note") or notes.get(s["title"])
        if note:
            entry["note"] = note
        sections.append(entry)
    return sections


# ── Requirements bullets ──

def build_bullets(j, t):
    b = ["description: " + t["description"].rstrip(".") + "."]
    if t.get("words"):
        label = "recommended length" if t.get("wordsIsRecommended") else "body up to"
        note = t.get("wordsNote")
        extra = "" if not note or note in ("of text", "total") else f" ({note.rstrip('.')})"
        b.append(f"limits: {label} {fmt(t['words'])} words{extra}")
    abstract = t.get("abstract")
    if abstract == "none":
        b.append("limits: no abstract" + ("" if t.get("keyPoints") else " and no Key Points"))
    elif t.get("abstractWords"):
        b.append(f"limits: {abstract} abstract up to {t['abstractWords']} words")
    elif abstract:
        b.append(f"limits: {abstract} abstract")
    if t.get("keyPoints"):
        b.append(f"limits: Key Points up to {KEY_POINTS_WORDS} words")
    if t.get("referencesMax"):
        b.append(f"limits: {t['referencesMin']}–{t['referencesMax']} references" if t.get("referencesMin")
                 else f"limits: up to {t['referencesMax']} references")
    if t.get("tablesFiguresCombined"):
        n = t["tablesFiguresCombined"]
        b.append(f"limits: up to {n} tables and figures combined" if n != 1 else "limits: 1 table or figure at most")
    if t.get("figuresMax"):
        b.append(f"limits: up to {t['figuresMax']} figure{'s' if t['figuresMax'] != 1 else ''}")
    if t.get("tablesMax"):
        b.append(f"limits: up to {t['tablesMax']} table{'s' if t['tablesMax'] != 1 else ''}")
    if t.get("authorsMax"):
        b.append(f"limits: up to {t['authorsMax']} author{'s' if t['authorsMax'] != 1 else ''}")
    b.append(f"limits: title up to {t['titleChars']} characters including spaces")

    b.append("components: required sections: " + ", ".join(s["title"] for s in t["sections"] if s.get("required", True)))
    if abstract == "structured" and t.get("abstractHeadings"):
        b.append("components: structured abstract under " + layout_text(t["abstractHeadings"]))
    if t.get("keyPoints"):
        b.append("components: Key Points — Question (1 sentence), Findings (1–2 sentences), Meaning (1 sentence) — placed before the abstract")
    if t.get("subtitle"):
        b.append("components: subtitle " + " or ".join(f"“{s}”" for s in t["subtitle"]))
    for key in t["requirements"]:
        b.append("components: " + REQUIREMENT_CHECKS[key][0])
    if t.get("presubmissionInquiry"):
        b.append("components: presubmission inquiry required before submitting")
    if t.get("patientPermission"):
        b.append("components: signed JAMA Network Patient Permission form for any identifiable patient")
    if abstract and abstract != "none":
        b.append(ACKNOWLEDGMENT_BULLET)
    status = cover_letter(j)
    if status == "required":
        b.append("components: cover letter — " + COVER_LETTER)
    elif status == "recommended":
        b.append("components: cover letter recommended, not required — " + COVER_LETTER)
    else:
        b.append("components: no cover letter — the submission form asks for its contents")

    b += FORMAT_BULLETS
    for extra in j.get("formatBullets", []):
        b.append("format: " + extra)
    for n in t["notes"]:
        b.append("extra: " + n.rstrip(".") + ".")
    b.append(DISCLAIMER)
    return b


# ── Writing ──

def dump(obj):
    return json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def profile_files(j, t):
    slug = slugify(j["journal"], t["name"])
    pid = bundled_id(slug)
    requirements = {
        "articleType": t["name"], "bullets": build_bullets(j, t), "country": COUNTRY,
        "id": pid, "journal": j["journal"], "publisher": PUBLISHER,
        "updatedAt": STAMP, "url": j["url"],
    }
    checks = {"checks": build_checks(j, t), "id": pid, "journal": j["journal"], "updatedAt": STAMP}
    structure = {"id": pid, "journal": j["journal"], "sections": build_structure(j, t)}
    return slug, {"requirements.json": dump(requirements), "checks.json": dump(checks),
                  "structure.json": dump(structure)}


def main(check_only=False):
    stale, written, total, produced = [], 0, 0, set()
    for spec_path in sorted(SPECS.glob("*.json")):
        j = json.loads(spec_path.read_text())
        types = [t for t in j["articleTypes"] if not is_dropped(t)]
        for t in types:
            slug, files = profile_files(j, normalize(t))
            produced.add(slug)
            folder = OUT / slug
            for name, text in files.items():
                path = folder / name
                if path.exists() and path.read_text() == text:
                    continue
                if check_only:
                    stale.append(str(path.relative_to(ROOT)))
                else:
                    folder.mkdir(parents=True, exist_ok=True)
                    path.write_text(text)
                    written += 1
        total += len(types)
        print(f"{j['journal']}: {len(types)} article types")
    print(f"{total} profiles")
    # The generator owns the `jama-*` folders: one a spec no longer yields
    # is a stale profile, not a hand-made one.
    for folder in sorted(OUT.glob("jama-*")):
        if folder.is_dir() and folder.name not in produced:
            if check_only:
                stale.append(str(folder.relative_to(ROOT)) + " (no spec yields it)")
            else:
                shutil.rmtree(folder)
                print(f"removed {folder.name}")
    if check_only:
        if stale:
            print("STALE:\n  " + "\n  ".join(stale))
            return 1
        print("every generated profile is current")
        return 0
    print(f"wrote {written} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(check_only="--check" in sys.argv))
