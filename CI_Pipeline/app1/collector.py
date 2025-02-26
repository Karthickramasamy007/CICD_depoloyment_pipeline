from flask import Flask, jsonify
import logging
from utils.logger import LoggerHandler

# logging config
log_level = "DEBUG"
LoggerHandler('collector', log_level).setup_logger()
logger = logging.getLogger('demo-app-flask')

app = Flask(__name__)

booksList = [
    {
        "id": 1,
        "title": "CS50",
        "description": "Intro to CS and art of programming!",
        "author": "Havard",
        "borrowed": False
    },
    {
        "id": 2,
        "title": "Python 101",
        "description": "little python code bookss.",
        "author": "Will",
        "borrowed": False
    }
]


@app.route('/books')
def books():
    return jsonify({"Books": booksList})

@app.route('/')
def main():
    return "This is main page"