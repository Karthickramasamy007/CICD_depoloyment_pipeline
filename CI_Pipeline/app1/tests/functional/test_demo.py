import json
from collector import app

def test_get_all_books():
    response = app.test_client().get('/books')
    res = json.loads(response.data.decode('utf-8')).get("Books")
    assert type(res[0]) is dict
    assert type(res[1]) is dict
    assert res[0]['author'] == 'Havard'
    assert res[1]['author'] == 'Will'
    assert response.status_code == 200
    assert type(res) is list