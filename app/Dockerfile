FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

RUN useradd --uid 10001 --no-create-home app
USER app

ENV PORT=8000
EXPOSE 8000
CMD ["python", "main.py"]
