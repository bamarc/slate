"""Domain packages — business domains organised by bounded context.

Each domain is a self-contained package with its own:
- ``models.py`` — SQLAlchemy ORM models
- ``schemas.py`` — Pydantic request/response schemas
- ``repository.py`` — data access layer
- ``service.py`` — business logic
- ``router.py`` — FastAPI routes (thin, delegates to service)
"""
