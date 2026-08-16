"""Build the ClinicGuard RAG knowledge base.

Pipeline (run from server/ with the .env that configures Supabase + embeddings):
  1. Download MedQuAD (CC BY 4.0, 47k NIH QA pairs) if not cached.
  2. Parse the XML QA collections, filter to primary-care topics, dedupe, chunk.
  3. Merge the hand-curated ClinicGuard snippets (rag_data/clinicguard_snippets.json).
  4. Embed everything via the configured EMBEDDING_* provider and upsert into
     Supabase pgvector (knowledge_chunks) through the same Store used by the API.

Usage:
  uv run python scripts/rag_build.py                # full build
  uv run python scripts/rag_build.py --max-chunks 300   # smaller demo set
  uv run python scripts/rag_build.py --skip-download    # reuse cached zip
  uv run python scripts/rag_build.py --verify           # stats + sample queries (no rebuild)

Notes:
  - The Supabase `vector` extension must be enabled once (dashboard SQL editor:
    `create extension vector;`) or the upsert will fail with a clear error.
  - No Supabase configured? The build stores into the in-memory store (useful
    for local tests; the demo server then retrieves from memory with a naive
    token-overlap scorer).
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import re
import sys
import urllib.request
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

# Allow `python scripts/rag_build.py` from anywhere: `store`, `config`, `rag`
# live one level up (the server package root).
SERVER_ROOT = Path(__file__).resolve().parent.parent
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

RAG_DATA = SERVER_ROOT / "rag_data"
MEDQUAD_ZIP = RAG_DATA / "medquad.zip"
MEDQUAD_DIR = RAG_DATA / "medquad"
MEDQUAD_URL = "https://github.com/abachaa/MedQuAD/archive/refs/heads/master.zip"
SNIPPETS_FILE = RAG_DATA / "clinicguard_snippets.json"

# Collections whose answers are present in the repo (3 MedlinePlus subsets had
# answers removed for copyright; GARD is rare-disease focused -> skip).
COLLECTIONS = [
    "5_NIDDK_QA", "6_NINDS_QA", "8_NHLBI_QA_XML", "9_CDC_QA",
    "7_SeniorHealth_QA", "1_CancerGov_QA", "3_GHR_QA", "4_MPlus_Health_Topics_QA",
]

# Primary-care relevance filter (matches Focus/Question/Answer, case-insensitive).
TOPIC_TERMS = re.compile(
    r"\b(fever|cold|flu|cough|sore throat|headache|migraine|blood pressure|hypertension|"
    r"diabetes|allerg|asthma|wheez|medication|antibiotic|drug|pain|stomach|nausea|"
    r"vomiting|diarrhea|dehydration|vaccin|immuniz|infection|pneumonia|bronchitis|"
    r"arthritis|back pain|sleep|insomnia|fatigue|cholesterol|heart|exercise|weight|"
    r"smoking|pregnancy|thyroid|kidney|urinary|constipation|heartburn|acidity|"
    r"skin rash|eczema|hives|ear pain|eye|dental|tooth|menstrual|period pain|"
    r"depression|anxiety|stress|dizziness|first aid|injury|burn|wound|sting|bite)\b",
    re.IGNORECASE,
)

MAX_CHUNK_CHARS = 1800  # long answers are split by paragraph into ~500-token chunks


def download() -> None:
    RAG_DATA.mkdir(parents=True, exist_ok=True)
    if MEDQUAD_ZIP.exists() and MEDQUAD_DIR.exists():
        print(f"[1/5] MedQuAD already cached ({MEDQUAD_DIR})")
        return
    print(f"[1/5] downloading MedQuAD (CC BY 4.0) from {MEDQUAD_URL} ...")
    urllib.request.urlretrieve(MEDQUAD_URL, MEDQUAD_ZIP)
    with zipfile.ZipFile(MEDQUAD_ZIP) as zf:
        zf.extractall(MEDQUAD_DIR)
    print(f"[1/5] extracted to {MEDQUAD_DIR}")


def parse_collection(path: Path) -> list[dict]:
    docs: list[dict] = []
    for xml_file in sorted(path.glob("*.xml")):
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            continue
        focus = (root.findtext("Focus") or "").strip()
        url = root.get("url", "")
        for qa in root.findall("./QAPairs/QAPair"):
            question = (qa.findtext("Question") or "").strip()
            answer = (qa.findtext("Answer") or "").strip()
            if not question or not answer:
                continue
            docs.append(
                {
                    "title": question,
                    "category": "general",
                    "content": answer,
                    "source": f"MedQuAD: {focus} ({url})",
                }
            )
    return docs


def split_chunks(doc: dict) -> list[dict]:
    content = doc["content"]
    if len(content) <= MAX_CHUNK_CHARS:
        return [doc]
    # Long answer: split on paragraph boundaries, keep each chunk self-contained.
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", content) if p.strip()]
    chunks: list[dict] = []
    buf = ""
    for p in paragraphs:
        if len(buf) + len(p) + 2 > MAX_CHUNK_CHARS and buf:
            chunks.append({**doc, "content": buf})
            buf = p
        else:
            buf = f"{buf}\n\n{p}".strip() if buf else p
    if buf:
        chunks.append({**doc, "content": buf})
    return chunks


def build_corpus(max_chunks: int) -> list[dict]:
    print("[2/5] parsing MedQuAD collections (skipping answerless/copyrighted subsets)")
    all_docs: list[dict] = []
    per_collection: Counter[str] = Counter()
    for name in COLLECTIONS:
        col_dir = MEDQUAD_DIR / "MedQuAD-master" / name
        if not col_dir.exists():
            continue
        docs = parse_collection(col_dir)
        kept = [d for d in docs if TOPIC_TERMS.search(f"{d['title']} {d['content']}")]
        per_collection[name] = len(kept)
        all_docs.extend(kept)
    print("  topic-filtered per collection:", dict(per_collection))

    seen: set[str] = set()
    unique: list[dict] = []
    for d in all_docs:
        key = hashlib.sha1(d["content"].encode()).hexdigest()
        if key in seen:
            continue
        seen.add(key)
        unique.append(d)
    print(f"  {len(all_docs)} filtered -> {len(unique)} after dedupe")

    chunks: list[dict] = []
    for d in unique:
        chunks.extend(split_chunks(d))
        if len(chunks) >= max_chunks:
            break
    print(f"  {len(chunks)} chunks (capped at {max_chunks})")

    print(f"[3/5] adding curated ClinicGuard snippets ({SNIPPETS_FILE.name})")
    curated = json.loads(SNIPPETS_FILE.read_text())
    for c in curated:
        chunks.append(c)
    print(f"  total corpus: {len(chunks)} chunks")
    return chunks


async def verify(store) -> None:
    count = await store.count_knowledge()
    print(f"[verify] knowledge_chunks: {count}")
    queries = [
        "What should I do for a fever?",
        "My chest hurts and I feel nauseous",
        "How do I use my asthma inhaler?",
        "What are the signs of low blood sugar?",
        "I want to book an appointment",
    ]
    for q in queries:
        results = await store.search_knowledge(q, k=3)
        print(f"\n  query: {q!r}")
        for r in results:
            sim = r.get("similarity")
            sim_str = f"  sim={sim:.3f}" if isinstance(sim, float) else ""
            print(f"    - [{r.get('category')}]{sim_str} {r.get('title', '')[:70]}")


async def _run(args: argparse.Namespace) -> None:
    from store import get_store

    store = get_store()

    if args.verify:
        await verify(store)
        return

    if args.wipe:
        import shutil

        shutil.rmtree(MEDQUAD_DIR, ignore_errors=True)
        MEDQUAD_ZIP.unlink(missing_ok=True)

    if not args.skip_download:
        download()
    if not MEDQUAD_DIR.exists():
        print("ERROR: MedQuAD not downloaded; run without --skip-download", file=sys.stderr)
        sys.exit(1)

    chunks = build_corpus(args.max_chunks)

    from rag import embeddings

    print(f"[4/5] embedding {len(chunks)} chunks via {embeddings.model_name()!r}")
    try:
        vectors = embeddings.embed_texts([c["content"] for c in chunks])
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(
            "  Set EMBEDDING_BASE_URL/EMBEDDING_API_KEY/EMBEDDING_MODEL (or OPENAI_API_KEY) in server/.env",
            file=sys.stderr,
        )
        sys.exit(1)
    for chunk, vec in zip(chunks, vectors):
        chunk["embedding"] = vec

    print(f"[5/5] upserting into {'Supabase' if store._use_supabase else 'in-memory store'}")
    try:
        inserted = await store.upsert_knowledge(chunks)
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if "vector" in msg.lower() and "extension" in msg.lower():
            print(
                "ERROR: pgvector extension missing. Run once in the Supabase SQL editor:\n"
                "  create extension vector;",
                file=sys.stderr,
            )
        raise

    total = await store.count_knowledge()
    by_cat = Counter(c.get("category", "general") for c in chunks)
    print(f"inserted {inserted} (store total: {total})")
    print("categories:", dict(by_cat.most_common()))
    print("sources: MedQuAD CC BY 4.0 (https://github.com/abachaa/MedQuAD) + ClinicGuard curated demo snippets (not medical advice)")
    await verify(store)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--max-chunks", type=int, default=1500, help="MedQuAD chunk cap")
    ap.add_argument("--skip-download", action="store_true")
    ap.add_argument("--verify", action="store_true", help="stats + sample queries only")
    ap.add_argument("--wipe", action="store_true", help="delete cached download first")
    args = ap.parse_args()
    asyncio.run(_run(args))


if __name__ == "__main__":
    main()
