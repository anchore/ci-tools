FROM node:latest

RUN mkdir -p /home/node/ && apt-get update && apt-get -y upgrade && apt-get -y install curl
COPY ./app/ /home/node/app/

# DEV NOTE: remember to re-enable healthcheck and remove debugging port 22 before final push!

HEALTHCHECK CMD curl --fail http://localhost:8081/ || exit 1
EXPOSE 8081

USER node
CMD node /home/node/app/server.js
