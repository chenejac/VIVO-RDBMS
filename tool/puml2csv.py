#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
puml2csv_semantic_final.py
Parse PlantUML and generate CSVs with semantic fake data, FK consistency, M:N join tables,
association entities preserved, and many dataset-specific rules.
Python 3.
Usage:
    python3 puml2csv_semantic_final.py model.puml out_dir [rows]
"""
import re, os, sys, csv, random

# ---------------- Semantic pools and helpers ----------------
DOC_TITLES = [
    "AI in Education", "Knowledge Graphs", "Quantum Research",
    "Cloud Computing", "Open Science", "Machine Learning for Healthcare",
    "Semantic Web Technologies", "Data Science for Policy"
]
FIRSTNAMES = ["Ana", "Marko", "Jelena", "Petar", "Ivana", "Nikola", "Maja", "Milos", "Luka", "Sara"]
LASTNAMES = ["Petrovic", "Garcia", "Smith", "Ivanov", "Chen", "Silva", "Jovanovic", "Kovacevic"]
JOURNAL_TITLES = ["AI Review", "Information Systems", "Data Science Journal", "Computing Advances"]
JOURNAL_ABBREV = ["AI Rev.", "Info. Syst.", "DSJ", "Comp. Adv."]
EVENT_NAMES = ["AIConf 2025", "Open Science Summit", "Quantum Symposium", "Cloud Expo Europe"]
GEO_NAMES = ["Serbia", "Germany", "USA", "France", "Spain"]
GEO_CODES = {"Serbia":"RS","Germany":"DE","USA":"US","France":"FR","Spain":"ES"}
GRANT_NAMES = ["HorizonEurope Project X", "National Science Grant Y", "AI Innovation Programme", "Climate Research Initiative"]
INVESTIGATOR_ROLES = ["Principal Investigator", "Co-Principal Investigator", "Investigator"]
ADVISORY_TYPES = ["Advising", "Faculty Mentoring", "Graduate Advising", "Postdoc or Fellow Advising", "Undergraduate Advising"]
CITATION_SOURCES = ["OpenAlex", "Web of Science", "Scopus"]
POSITION_TYPES = ["faculty position", "non-academic position"]
POSITION_TITLES = ["full professor","librarian","developer"]
ORG_TYPES = ["Faculty","Research Center","Research Institute","College","NGO"]
ORG_NAMES = ["University of Belgrade", "Faculty of Science", "Institute of AI", "Research Center VINCA", "Open Data Lab"]


def make_orcid():
    # generate pseudo-ORCID like 0000-0002-1825-0097
    def block():
        return "%04d" % random.randint(0,9999)
    return "-".join(block() for _ in range(4))

def make_issn():
    return "%04d-%04d" % (random.randint(1000,9999), random.randint(1000,9999))

def make_ror():
    # pseudo ROR id: ror.org/xxxxx - realistic RORs have 9-char id starting with 0..9/letters, but we fake plausible
    suffix = "".join(random.choice("0123456789abcdefghijklmnopqrstuvwxyz") for _ in range(9))
    return "https://ror.org/" + suffix

def make_abbrev(name):
    # simple abbreviation generator: take capitals or first letters
    parts = re.split(r'[\s_\-]+', name)
    if len(parts) == 1:
        return name[:4].upper()
    abb = "".join(p[0].upper() for p in parts if p)
    return abb[:6]

# ---------------- PUML parsing ----------------
def parse_puml(path):
    entities = {}
    relations = []  # dicts: left, connector, right
    current = None
    with open(path, 'r', encoding='utf-8') as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("'"):
                continue
            # entity start
            m = re.match(r'^entity\s+([A-Za-z0-9_]+)', line)
            if m:
                current = m.group(1)
                entities[current] = []
                continue
            # end
            if current and line.startswith('}'):
                current = None
                continue
            # attribute
            if current and ':' in line:
                col = line.split(':',1)[0].strip()
                if col and col != '--':
                    entities[current].append(col)
                continue
            # relation
            if '--' in line:
                parts = re.split(r'\s+', line)
                if len(parts) >= 3:
                    left, connector, right = parts[0], parts[1], parts[2]
                    relations.append({'left': left, 'connector': connector, 'right': right})
    return entities, relations

# ---------------- Core generation logic ----------------
def detect_assoc_entities(entities, relations):
    degree = {}
    for r in relations:
        degree[r['left']] = degree.get(r['left'], 0) + 1
        degree[r['right']] = degree.get(r['right'], 0) + 1
    assoc = set()
    for ent, cols in entities.items():
        if len(cols) > 0 and degree.get(ent,0) >= 2:
            assoc.add(ent)
    return assoc

def is_mn(conn):
    return '}' in conn and '{' in conn

def is_1n(conn):
    return '||--o{' in conn or '|o--o{' in conn

def generate_csvs(entities, relations, out_dir, rows=5):
    if not os.path.exists(out_dir):
        os.makedirs(out_dir)

    assoc = detect_assoc_entities(entities, relations)

    # Decide where FK columns go.
    # Special-case: if left is Document and connector is |o--o{ to Journal/Event, FK goes in Document (user requirement).
    # General rule: for '|o--o{' treat left as child -> FK in left; for '||--o{' treat left as parent -> FK in right.
    for r in relations:
        left, conn, right = r['left'], r['connector'], r['right']
        if is_mn(conn):
            continue
        # don't add FK linking association entities (they remain separate)
        if left in assoc or right in assoc:
            continue
        if '|o--o{' in conn:
            # left is child (e.g., Document |o--o{ Journal -> document has journal_id)
            fk_col = right.lower() + "_id"
            if fk_col not in entities[left]:
                entities[left].append(fk_col)
        elif '||--o{' in conn:
            # left is parent, right is child (left ||--o{ right) -> FK in right
            fk_col = left.lower() + "_id"
            if fk_col not in entities[right]:
                entities[right].append(fk_col)
        else:
            # fallback: if left == Document and right in Journal/Event, put FK in Document
            if left == "Document" and right in ("Journal","Event"):
                fk_col = right.lower() + "_id"
                if fk_col not in entities[left]:
                    entities[left].append(fk_col)
            else:
                # default: FK in right
                fk_col = left.lower() + "_id"
                if fk_col not in entities[right]:
                    entities[right].append(fk_col)

    # Pre-generate PKs lists for each entity (if entity has <entity>_id column use that)
    pk_values = {}
    for ent, cols in entities.items():
        ent_id_col = None
        lowered = [c.lower() for c in cols]
        candidate = ent.lower() + "_id"
        if candidate in lowered:
            ent_id_col = cols[lowered.index(candidate)]
        else:
            # fallback to first _id
            for i,c in enumerate(lowered):
                if c.endswith("_id"):
                    ent_id_col = cols[i]
                    break
        if ent_id_col:
            pk_values[ent] = [i+1 for i in range(rows)]
        else:
            pk_values[ent] = []

    # Pre-generate persons data so authorship.display_author_name can reference them
    persons = {}
    if 'Person' in entities:
        # find person columns to know order
        person_cols = entities['Person']
        # ensure person_id exists?
        if not any(c.lower()== 'person_id' for c in person_cols):
            # we'll use index+1 as person_id even if absent
            pass
        for i in range(len(pk_values.get('Person', [1]))):
            pid = pk_values.get('Person', [1])[i]
            firstname = random.choice(FIRSTNAMES)
            lastname = random.choice(LASTNAMES)
            # other_name as father's name
            other_name = random.choice(FIRSTNAMES)
            orcid = make_orcid()
            persons[str(pid)] = {
                'person_id': pid,
                'firstname': firstname,
                'lastname': lastname,
                'other_name': other_name,
                'orcid': orcid
            }

    # Helper to pick existing PK from an entity
    def pick_pk(ent):
        vals = pk_values.get(ent)
        if vals:
            return random.choice(vals)
        # fallback: random small int
        return random.randint(1, max(1, rows))

    # Now write entity CSVs with semantic values
    for ent, cols in entities.items():
        fname = os.path.join(out_dir, ent.lower() + ".csv")
        with open(fname, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(cols)
            for idx in range(rows):
                row = []
                for c in cols:
                    cl = c.lower()

                    # deterministic entity PK if present
                    if cl == ent.lower() + "_id" and pk_values.get(ent):
                        row.append(pk_values[ent][idx % len(pk_values[ent])])
                        continue

                    # special per-column rules
                    if ent == "Authorship" and cl == "display_author_name":
                        # need a person FK on this row - prefer authorship has person_id column; find person_id in columns
                        # If person_id exists, we'll fill it and then use it
                        # Here we'll choose random person and concat firstname+lastname
                        pid = pick_pk('Person')
                        person = persons.get(str(pid)) or {'firstname': random.choice(FIRSTNAMES), 'lastname': random.choice(LASTNAMES)}
                        row.append(person['firstname'] + " " + person['lastname'])
                        continue

                    if ent == "Citations" and cl in ("source","citation_source"):
                        row.append(random.choice(CITATION_SOURCES))
                        continue
                    if ent == "Citations" and cl in ("number","citation_number"):
                        row.append(random.randint(1,500))
                        continue

                    if ent == "Document" and cl == "page_start":
                        # generate then ensure page_end larger
                        pstart = random.randint(1,200)
                        row.append(pstart)
                        continue
                    if ent == "Document" and cl == "page_end":
                        # ensure > page_start
                        # We need previous value page_start from this row (we may not have it if columns order different)
                        # Safer approach: pick start then pick end > start
                        # find index of page_start in cols
                        try:
                            ps_idx = [cc.lower() for cc in cols].index('page_start')
                            # if that column is earlier, use the value we already wrote in row
                            if ps_idx < len(row):
                                start_val = int(row[ps_idx])
                                end_val = start_val + random.randint(1, 30)
                                row.append(end_val)
                                continue
                        except ValueError:
                            pass
                        # fallback
                        row.append(random.randint(2, 400))
                        continue

                    if ent == "Advisorship":
                        # prefer columns: advisor_person_id, student_person_id, advising_relationship_type
                        if 'advisor_person_id' in [x.lower() for x in cols] and cl == 'advisor_person_id':
                            # choose advisor
                            pr = pick_pk('Person')
                            row.append(pr)
                            continue
                        if 'student_person_id' in [x.lower() for x in cols] and cl == 'student_person_id':
                            # choose student distinct from advisor (if advisor chosen already)
                            # get last appended advisor if present
                            advisor_val = None
                            # find advisor column index
                            try:
                                aidx = [cc.lower() for cc in cols].index('advisor_person_id')
                                if aidx < len(row):
                                    advisor_val = row[aidx]
                            except ValueError:
                                advisor_val = None
                            s = pick_pk('Person')
                            attempts = 0
                            while advisor_val is not None and str(s) == str(advisor_val) and attempts < 10:
                                s = pick_pk('Person'); attempts += 1
                            row.append(s)
                            continue
                        if cl == 'advising_relationship_type':
                            row.append(random.choice(ADVISORY_TYPES))
                            continue

                    if ent == "Event" and cl == "name":
                        row.append(random.choice(EVENT_NAMES))
                        continue

                    if ent == "Geolocation":
                        if cl == "name":
                            row.append(random.choice(GEO_NAMES))
                            continue
                        if cl == "code":
                            # pick matching code for name if possible; otherwise random ISO-like
                            # simple: choose pair
                            name = random.choice(GEO_NAMES)
                            row.append(GEO_CODES.get(name, "XX"))
                            continue

                    if ent == "Grant" and cl == "name":
                        row.append(random.choice(GRANT_NAMES))
                        continue
                    if ent == "Grant" and cl == "total_award_amount":
                        # produce number in USD, e.g., 2400000 -> 2.4 million; user asked e.g. 2.4 millions
                        millions = round(random.uniform(0.5, 5.0), 2)
                        # store as number of USD
                        row.append(millions * 1_000_000)
                        continue

                    if ent.lower() == "investigatorship" or (ent == "Contributorship" and cl in ("roletype","roletype".lower(), "roleType".lower())):
                        # some PUML use roleType; we try to fill role_type etc.
                        if "role" in cl:
                            row.append(random.choice(INVESTIGATOR_ROLES))
                            continue

                    if ent == "Journal":
                        if cl == "title":
                            # pick from JOURNAL_TITLES
                            t = random.choice(JOURNAL_TITLES)
                            row.append(t)
                            continue
                        if cl == "abbreviation":
                            # derive from title
                            t = random.choice(JOURNAL_TITLES)
                            row.append(make_abbrev(t))
                            continue
                        if cl == "issn":
                            row.append(make_issn())
                            continue

                    if ent == "OrganisationUnit":
                        if cl == "abbreviation":
                            row.append(make_abbrev(random.choice(ORG_NAMES)))
                            continue
                        if cl == "ror":
                            row.append(make_ror())
                            continue
                        if cl == "type":
                            row.append(random.choice(ORG_TYPES))
                            continue

                    if ent == "Person":
                        if cl == "other_name":
                            # father's name
                            row.append(random.choice(FIRSTNAMES))
                            continue
                        if cl == "preferred_title":
                            row.append(random.choice(PREFERRED_TITLES))
                            continue
                        if cl == "orcid":
                            row.append(make_orcid())
                            continue
                        if cl == "type":
                            row.append(random.choice(PERSON_TYPES))
                            continue

                    if ent == "Position" and cl == "type":
                        row.append(random.choice(POSITION_TYPES))
                        continue
						
                    if ent == "Position" and cl == "title":
                        row.append(random.choice(POSITION_TITLES))
                        continue

                    # default behaviors for numeric-like columns
                    if cl in ("publication_year","start_year","end_year"):
                        row.append(random.randint(1990,2025))
                        continue

                    # general FK columns (xxx_id)
                    if cl.endswith("_id"):
                        ref = cl[:-3]
                        # pick from pk_values if exists
                        val = pick_pk_for_ref(pk_values, ref, rows)
                        row.append(val)
                        continue

                    # default synthesized value
                    row.append(synth_generic_value(cl))

                writer.writerow(row)

    # Create M:N join tables (document_researcharea, person_researcharea, etc.)
    for r in relations:
        if is_mn(r['connector']):
            left, right = r['left'], r['right']
            key = f"{left.lower()}_{right.lower()}"
            fname = os.path.join(out_dir, key + ".csv")
            left_vals = pk_values.get(left) or [1]
            right_vals = pk_values.get(right) or [1]
            with open(fname, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                writer.writerow([f"{left.lower()}_id", f"{right.lower()}_id"])
                # include coverage: each PK at least once
                pairs = []
                minlen = min(len(left_vals), len(right_vals))
                for i in range(minlen):
                    pairs.append((left_vals[i % len(left_vals)], right_vals[i % len(right_vals)]))
                while len(pairs) < rows:
                    pairs.append((random.choice(left_vals), random.choice(right_vals)))
                for a,b in pairs[:rows]:
                    writer.writerow([a,b])

    print("Done. CSVs in:", out_dir)

# Helper functions used in generation (defined below to keep main clean)
def pick_pk_for_ref(pk_values, ref, rows):
    # try matches like 'Journal' for ref 'journal'
    for k in pk_values:
        if k.lower() == ref.lower():
            vals = pk_values[k]
            if vals:
                return random.choice(vals)
    # fallback random
    return random.randint(1, max(1, rows))

def synth_generic_value(col_lower):
    # fallback generic generator
    if 'name' in col_lower:
        return random.choice(ORG_NAMES + FIRSTNAMES)
    if 'title' in col_lower:
        return random.choice(DOC_TITLES)
    if 'doi' in col_lower:
        return f"10.{random.randint(100,999)}/{random.randint(1000,9999)}"
    if 'issn' in col_lower:
        return make_issn()
    if 'isbn' in col_lower:
        return str(random.randint(1000000000,9999999999))
    if 'page' in col_lower or 'volume' in col_lower or 'issue' in col_lower:
        return random.randint(1,200)
    return f"{col_lower}_{random.randint(1,100)}"

# ---------------- Main CLI ----------------
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 puml2csv_semantic_final.py model.puml out_dir [rows]")
        sys.exit(1)
    puml = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "csv_final"
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 5

    ents, rels = parse_puml(puml)
    generate_csvs(ents, rels, out_dir, rows)
