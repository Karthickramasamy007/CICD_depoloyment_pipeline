import logging

class LoggerHandler:
    """
    Fake file-like stream object that redirects writes to a logger instance.
    """

    def __init__(self, logger_instance='root', level='Info'):
        self.logger_instance = logger_instance
        self.level = level
        self.logger = None

    def setup_logger(self):

        log_level = self.level
        numeric_log_level = getattr(logging, log_level.upper(), None)

        # Logger Formatter
        formatter = logging.Formatter(
            '%(asctime)s - %(name)s - %(levelname)s - %(message)s')

        # Initialize Default Logger
        self.logger = logging.getLogger(self.logger_instance)
        self.logger.setLevel(numeric_log_level)

        # Initialize StreamHandler
        ch = logging.StreamHandler()
        ch.setLevel(numeric_log_level)
        ch.setFormatter(formatter)
        self.logger.addHandler(ch)
        
        #Flask main page
        logger = logging.getLogger('demo-app-flask')
        logger.setLevel(numeric_log_level)
        logger.addHandler(ch)
        