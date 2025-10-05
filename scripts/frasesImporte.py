import os
import json
import argparse
import unicodedata
from datetime import datetime
from typing import Dict, Any, Tuple

import pandas as pd
from deep_translator import GoogleTranslator
from pymongo import MongoClient, ASCENDING
from pymongo.errors import PyMongoError, DuplicateKeyError
from dotenv import load_dotenv
from tqdm import tqdm

load_dotenv()  # Carga variables desde .env si existe


# ---------------------- CONEXIÓN ----------------------
def get_mongo_uri() -> str:
    uri = os.getenv('MONGODB_URI') or os.getenv('MONGO_URI')
    if not uri:
        raise RuntimeError(
            "No se encontró MONGODB_URI (o MONGO_URI) en las variables de entorno. "
            "Crea un archivo .env con MONGODB_URI='<tu_uri>'"
        )
    return uri


def get_client() -> MongoClient:
    return MongoClient(get_mongo_uri())


def ensure_indexes(db) -> None:
    coll = db.phrases
    # Único por texto normalizado + tipo
    coll.create_index([('text', ASCENDING), ('type', ASCENDING)], unique=True)


# ---------------------- NORMALIZACIÓN ----------------------
def canonicalize_text(s: str) -> str:
    """Normaliza texto para reducir falsos duplicados:
        - NFKC unicode
        - strip
        - reemplaza comillas tipográficas por simples
        - colapsa espacios múltiples
    """
    if not s:
        return ""
    s = unicodedata.normalize("NFKC", s)
    s = s.replace("“", "\"").replace("”", "\"").replace("‘", "'").replace("’", "'")
    s = " ".join(s.strip().split())
    return s


def normalize_doc(doc: Dict[str, Any]) -> Dict[str, Any]:
    now = datetime.utcnow()
    normalized = {
        'text': canonicalize_text(doc.get('text') or ''),
        'author': doc.get('author', 'Desconocido'),
        'type': doc.get('type', 'frase'),
        'language': doc.get('language', 'es'),
        'tags': doc.get('tags', []),
        'category': doc.get('category', None),
        'source': doc.get('source', 'importer'),
        'created_at': doc.get('created_at', now),
    }
    return normalized


def upsert_phrase(db, doc: Dict[str, Any]) -> Tuple[bool, str]:
    """Inserta o ignora si ya existe (por text+type).
       Devuelve (inserted: bool, reason: str) donde reason ∈ {"ok","exists","error"}.
    """
    coll = db.phrases
    normalized = normalize_doc(doc)
    if not normalized['text']:
        return (False, "error")
    filter_q = {'text': normalized['text'], 'type': normalized['type']}
    update = {'$setOnInsert': normalized}
    try:
        result = coll.update_one(filter_q, update, upsert=True)
        if result.upserted_id is not None:
            return (True, "ok")
        else:
            return (False, "exists")
    except DuplicateKeyError:
        return (False, "exists")
    except PyMongoError as e:
        print(f"Error al insertar: {e}")
        return (False, "error")


# ---------------------- TRADUCCIÓN (con caché) ----------------------
_translate_cache: Dict[str, str] = {}

def translate_text(text: str, src: str = "en", target: str = "es") -> str:
    key = (src + "→" + target + "||" + text)
    if key in _translate_cache:
        return _translate_cache[key]
    try:
        translated = GoogleTranslator(source=src, target=target).translate(text)
        translated = canonicalize_text(translated)
        _translate_cache[key] = translated
        return translated
    except Exception as e:
        print(f"[WARN] Falló traducción: {e}")
        _translate_cache[key] = text
        return text


# ---------------------- IMPORTAR DATASET ----------------------
def import_kaggle_quotes(db, filepath: str) -> Dict[str, int]:
    """
    Importa el Quotes Dataset con campos:
    Quote, Author, Tags, Category, Popularity
    Traduce cada frase al español y guarda EN y ES.
    """
    print(f"Cargando dataset: {filepath}")

    # Leer archivo
    if filepath.endswith(".csv"):
        df = pd.read_csv(filepath)
    elif filepath.endswith(".json"):
        df = pd.read_json(filepath)
    else:
        raise ValueError("Formato no soportado (usa CSV o JSON).")

    # Renombrar columnas para uniformar
    df.rename(
        columns={
            "Quote": "quote",
            "Author": "author",
            "Tags": "tags",
            "Category": "category"
        },
        inplace=True,
    )

    inserted = 0
    skipped_existing = 0
    failed = 0

    # Barra de progreso
    for _, row in tqdm(df.iterrows(), total=len(df), desc="Importando citas"):
        raw_text = row.get("quote", "")
        text = canonicalize_text(str(raw_text))
        if not text:
            failed += 1
            continue

        author = canonicalize_text(str(row.get("author", "Desconocido")) or "Desconocido")

        tags = row.get("tags", [])
        if isinstance(tags, float):  # NaN
            tags = []
        elif isinstance(tags, str):
            tags = [canonicalize_text(t) for t in tags.split(",") if canonicalize_text(t)]

        category = row.get("category", None)
        if isinstance(category, float):  # NaN
            category = None
        category = canonicalize_text(str(category)) if category else None

        # 1) Versión EN
        doc_en = {
            "text": text,
            "author": author,
            "type": "frase",
            "language": "en",
            "tags": tags,
            "category": category,
            "source": "quotes_dataset",
        }
        ok, reason = upsert_phrase(db, doc_en)
        if ok:
            inserted += 1
        elif reason == "exists":
            skipped_existing += 1
        else:
            failed += 1

        # 2) Versión ES (traducción)
        text_es = translate_text(text, src="en", target="es")
        doc_es = {
            "text": text_es,
            "author": author,
            "type": "frase",
            "language": "es",
            "tags": tags,
            "category": category,
            "source": "quotes_dataset",
        }
        ok, reason = upsert_phrase(db, doc_es)
        if ok:
            inserted += 1
        elif reason == "exists":
            skipped_existing += 1
        else:
            failed += 1

    print(f"\n✅ Finalizado. Insertadas nuevas: {inserted} | Ya existentes: {skipped_existing} | Fallidas: {failed}")
    return {'inserted': inserted, 'skipped_existing': skipped_existing, 'failed': failed}


# ---------------------- UTILIDADES ----------------------
def list_phrases(db, limit: int = 10):
    coll = db.phrases
    for doc in coll.find().sort('created_at', -1).limit(limit):
        print(f"- ({doc.get('language')}) [{doc.get('type')}] {doc.get('text')[:100]} — {doc.get('author')}")


def count_phrases(db) -> int:
    return db.phrases.count_documents({})


# ---------------------- CLI ----------------------
def main():
    parser = argparse.ArgumentParser(description='Gestor de frases/poemas en MongoDB')
    sub = parser.add_subparsers(dest='cmd')

    kag = sub.add_parser('import_kaggle', help='Importa frases desde Quotes Dataset (CSV/JSON)')
    kag.add_argument('file', help='Ruta al dataset CSV o JSON')

    l = sub.add_parser('list', help='Lista frases recientes')
    l.add_argument('--limit', type=int, default=10)

    sub.add_parser('count', help='Cuenta frases en la BD')

    args = parser.parse_args()

    try:
        client = get_client()
        db = client.get_database(os.getenv('MONGODB_DATABASE', 'refra_poetry'))
        ensure_indexes(db)
    except Exception as e:
        print(f"No se pudo conectar a MongoDB: {e}")
        return

    if args.cmd == 'import_kaggle':
        res = import_kaggle_quotes(db, args.file)
        print(f"Insertadas: {res['inserted']} | Ya existentes: {res['skipped_existing']} | Fallidas: {res['failed']}")
    elif args.cmd == 'list':
        list_phrases(db, limit=args.limit)
    elif args.cmd == 'count':
        print(f"Total frases en BD: {count_phrases(db)}")
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
