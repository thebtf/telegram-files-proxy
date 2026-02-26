FROM aiogram/telegram-bot-api:latest

# Install nginx (Alpine-based image)
RUN apk add --no-cache nginx shadow

COPY wrapper-entrypoint.sh /wrapper-entrypoint.sh
RUN chmod +x /wrapper-entrypoint.sh

ENV ALLOWED_IPS=""
ENV PUID=1026
ENV PGID=100
ENV CLIENT_MAX_BODY_SIZE=20m

# 8081 = nginx (API proxy + file serving), 8082 = stats (direct from bot-api)
EXPOSE 8081 8082

ENTRYPOINT ["/wrapper-entrypoint.sh"]
