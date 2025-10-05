import os
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
from pymongo import MongoClient


load_dotenv()


def get_mongo_client():
    uri = os.getenv('MONGODB_URI') or os.getenv('MONGO_URI')
    if not uri:
        raise RuntimeError('MONGODB_URI no definido en .env')
    return MongoClient(uri)


app = FastAPI(title='Refra_Poetry API')

app.add_middleware(
    CORSMiddleware,
    allow_origins=['*'],
    allow_credentials=True,
    allow_methods=['*'],
    allow_headers=['*'],
)


client = get_mongo_client()
db = client.get_database(os.getenv('MONGODB_DATABASE', 'refra_poetry'))
phrases = db.phrases


@app.get('/quote')
def get_random_quote(language: Optional[str] = 'en'):
    try:
        pipeline = [{'$match': {'language': language}}, {'$sample': {'size': 1}}]
        docs = list(phrases.aggregate(pipeline))
        if not docs:
            # fallback: any language
            docs = list(phrases.aggregate([{'$sample': {'size': 1}}]))
            if not docs:
                raise HTTPException(status_code=404, detail='No quotes found')
        doc = docs[0]
        return {
            'content': doc.get('text', ''),
            'author': doc.get('author', 'Desconocido'),
            'language': doc.get('language', language),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == '__main__':
    import uvicorn

    uvicorn.run('api_server:app', host='0.0.0.0', port=8000, reload=True)
