
FROM nginx:alpine

ARG APP_FILE=index.html

COPY ${APP_FILE} /usr/share/nginx/html/index.html

EXPOSE 80

