# The store every harness talks to. Pinned exactly: this bench ages in weeks, and a
# store that drifted is a table nobody can contest.
#
# WEBrick, not falcon: this server answers one agent at a time and a pure-Ruby
# handler keeps the image free of a build toolchain. The engine's own server is a
# different question — nothing here is a statement about it.
FROM ruby:3.3.5-slim

RUN gem install --no-document rack:3.1.8 rackup:2.2.1 webrick:1.8.2

WORKDIR /app
COPY server.rb config.ru ./
COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/dump-state /usr/local/bin/wait-ready

ENV STORE_SEED=/seed/store.json
EXPOSE 8931
CMD ["rackup", "--server", "webrick", "--host", "0.0.0.0", "--port", "8931", "--env", "none"]
