FROM python:3.12-slim-bookworm

WORKDIR /app
COPY controller.py /app/controller.py
RUN chmod +x /app/controller.py

ENTRYPOINT ["python3", "-u", "/app/controller.py"]
