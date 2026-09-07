FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --create-home appuser
USER appuser

EXPOSE 8000
# WEB_CONCURRENCY lets the VPS's actual core count set worker count without
# rebuilding the image - tune it in .env.backend (guideline: 2x vCPU + 1).
# Defaults to today's known-safe value of 2 if unset.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${WEB_CONCURRENCY:-2}"]
