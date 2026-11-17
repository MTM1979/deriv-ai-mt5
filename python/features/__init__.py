"""Feature and data contracts shared by the research pipeline.

Import the concrete module you need, for example ``from features import spec``
or ``from features.spec import FEATURE_NAMES``. This package deliberately does
not re-export names eagerly: doing so imports ``features.spec`` before
``python -m features.spec`` runs, which triggers a runpy warning.
"""
