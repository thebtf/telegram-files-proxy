FROM nginx:alpine

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Data directory (mount telegram-bot-api appdata here)
VOLUME /data

ENV ALLOWED_IPS=""
ENV LISTEN_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
