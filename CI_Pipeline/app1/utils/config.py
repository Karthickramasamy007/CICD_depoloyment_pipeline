import os


class SetupConfig:

    def __init__(self, os_env):
        self.os_env = os_env

    def environment_config(self, app):

        if self.os_env == 'development':
            app.config.from_object('utils.config.DevelopmentConfig')
        elif self.os_env == 'testing':
            app.config.from_object('utils.config.TestingConfig')
        elif self.os_env == 'staging':
            app.config.from_object('utils.config.StagingConfig')
        elif self.os_env == 'production':
            app.config.from_object('utils.config.ProductionConfig')


class Config:
    DEBUG = False
    ALTIPLANO_METRICS_FILE = os.getenv('ALTIPLANO_METRICS_FILE', 'olt_metrics_config.yaml')


# Configuration for different environments
class ProductionConfig(Config):
    """Configuration for production."""
    ENV = 'production'


class StagingConfig(Config):
    """Configuration for staging."""
    ENV = 'staging'


class TestingConfig(Config):
    """Configuration for testing."""
    ENV = 'testing'
    DEBUG = True


class DevelopmentConfig(Config):
    """Configuration for development."""
    ENV = 'development'
    DEBUG = True
