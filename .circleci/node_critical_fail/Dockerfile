FROM node@sha256:899febf5a7af3bec94e9a67244087db218a42d55e748d9504b00019705bd3a18

RUN mkdir -p /home/node/ && apt-get update && apt-get -y install curl
COPY ./app/ /home/node/app/

# DEV NOTE: remember to re-enable healthcheck and remove debugging port 22 before final push!

# HEALTHCHECK CMD curl --fail http://localhost:8081/ || exit 1
EXPOSE 8081 22

CMD node /home/node/app/server.js
