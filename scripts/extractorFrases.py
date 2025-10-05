import os
import json
import argparse
from datetime import datetime
from typing import List, Dict, Any

from pymongo import MongoClient, ASCENDING
from pymongo.errors import PyMongoError
from dotenv import load_dotenv


load_dotenv()  # Carga variables desde .env si existe


def get_mongo_uri() -> str:
    """Obtiene la URI de MongoDB desde la variable de entorno MONGODB_URI.

    Por seguridad, evita mantener credenciales en el código fuente. Si no se
    encuentra la variable, el script termina con un mensaje explicativo.
    """
    uri = os.getenv('MONGODB_URI') or os.getenv('MONGO_URI')
    if not uri:
        raise RuntimeError(
            "No se encontró MONGODB_URI (o MONGO_URI) en las variables de entorno. Crea un archivo .env con MONGODB_URI='<tu_uri>'"
        )
    return uri


def get_client() -> MongoClient:
    uri = get_mongo_uri()
    client = MongoClient(uri)
    return client


def ensure_indexes(db) -> None:
    """Crea índices necesarios en la colección 'phrases' (único por text+type)."""
    coll = db.phrases
    coll.create_index([('text', ASCENDING), ('type', ASCENDING)], unique=True)


def normalize_doc(doc: Dict[str, Any]) -> Dict[str, Any]:
    now = datetime.utcnow()
    normalized = {
        'text': doc.get('text') or doc.get('content') or doc.get('quote') or '',
        'author': doc.get('author') or doc.get('from') or doc.get('source') or 'Desconocido',
        'type': doc.get('type', 'frase'),
        'language': doc.get('language', 'es'),
        'tags': doc.get('tags', []),
        'source': doc.get('source', 'importer'),
        'created_at': doc.get('created_at', now),
    }
    return normalized


def upsert_phrase(db, doc: Dict[str, Any]) -> bool:
    """Inserta o ignora un documento si ya existe (based en text + type).

    Retorna True si se insertó un nuevo documento, False si ya existía.
    """
    coll = db.phrases
    normalized = normalize_doc(doc)
    filter_q = {'text': normalized['text'], 'type': normalized['type']}
    update = {'$setOnInsert': normalized}
    try:
        result = coll.update_one(filter_q, update, upsert=True)
        # Si upserted_id no es None => se insertó
        return result.upserted_id is not None
    except PyMongoError as e:
        print(f"Error al insertar documento: {e}")
        return False


def insert_from_json(db, filepath: str) -> Dict[str, int]:
    """Lee un archivo JSON que contenga una lista de objetos y los inserta.

    Formato esperado: [ {"text": "...", "author": "...", "type": "poema", ...}, ... ]
    """
    with open(filepath, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError('El JSON debe ser una lista de objetos')
    inserted = 0
    skipped = 0
    for item in data:
        if upsert_phrase(db, item):
            inserted += 1
        else:
            skipped += 1
    return {'inserted': inserted, 'skipped': skipped}


def insert_from_text(db, filepath: str, type_: str = 'frase', author: str = 'Desconocido', language: str = 'es') -> Dict[str, int]:
    """Lee un archivo de texto y separa entradas por líneas vacías.

    Cada bloque de texto se considera una entrada (útil para poemas).
    """
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    blocks = [b.strip() for b in content.split('\n\n') if b.strip()]
    inserted = 0
    skipped = 0
    for block in blocks:
        doc = {'text': block, 'author': author, 'type': type_, 'language': language}
        if upsert_phrase(db, doc):
            inserted += 1
        else:
            skipped += 1
    return {'inserted': inserted, 'skipped': skipped}


def insert_sample(db):
    samples = [
        {"text": "No dejes para mañana lo que puedas hacer hoy.", "author": "Proverbio", "type": "refran", "language": "es", "tags": ["motivación"]},
        {"text": "La vida es aquello que te va sucediendo mientras estás ocupado haciendo otros planes.", "author": "John Lennon", "type": "frase", "language": "es"},
        {"text": "En el silencio se oyen las voces que el ruido ahoga.", "author": "Anónimo", "type": "reflexion", "language": "es"},
    ]
    inserted = 0
    for s in samples:
        if upsert_phrase(db, s):
            inserted += 1
    print(f"Insertadas {inserted} frases de ejemplo")


def list_phrases(db, limit: int = 20):
    coll = db.phrases
    for doc in coll.find().sort('created_at', -1).limit(limit):
        print(f"- [{doc.get('type')}] {doc.get('text')[:120]} -- {doc.get('author')}")


def count_phrases(db) -> int:
    return db.phrases.count_documents({})


def main():
    parser = argparse.ArgumentParser(description='Herramienta para insertar frases/poemas en MongoDB')
    sub = parser.add_subparsers(dest='cmd')

    sub.add_parser('sample', help='Inserta algunas frases de ejemplo')

    j = sub.add_parser('json', help='Inserta desde un archivo JSON (lista de objetos)')
    j.add_argument('file', help='Ruta al archivo JSON')

    t = sub.add_parser('text', help='Inserta desde un archivo de texto (separa por línea vacía)')
    t.add_argument('file', help='Ruta al archivo de texto')
    t.add_argument('--type', default='frase', help='Tipo: frase|poema|refran|reflexion')
    t.add_argument('--author', default='Desconocido')
    t.add_argument('--language', default='es')

    sub.add_parser('count', help='Muestra el número total de frases en la colección')
    l = sub.add_parser('list', help='Lista las frases recientes')
    l.add_argument('--limit', type=int, default=20)

    args = parser.parse_args()

    try:
        client = get_client()
        db = client.get_database(os.getenv('MONGODB_DATABASE', 'refra_poetry'))
        ensure_indexes(db)
    except Exception as e:
        print(f"No se pudo conectar a MongoDB: {e}")
        return

    if args.cmd == 'sample':
        insert_sample(db)
    elif args.cmd == 'json':
        res = insert_from_json(db, args.file)
        print(f"Insertadas: {res['inserted']}, Omitidas: {res['skipped']}")
    elif args.cmd == 'text':
        res = insert_from_text(db, args.file, type_=args.type, author=args.author, language=args.language)
        print(f"Insertadas: {res['inserted']}, Omitidas: {res['skipped']}")
    elif args.cmd == 'count':
        print(f"Total frases en BD: {count_phrases(db)}")
    elif args.cmd == 'list':
        list_phrases(db, limit=args.limit)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()