FROM ruby:3.3-alpine

WORKDIR /app
RUN addgroup -S photoapp && adduser -S -G photoapp -h /app photoapp
COPY --chown=photoapp:photoapp Gemfile Gemfile.lock README.md OPERATIONS.md PROVIDER_CONTRACTS.md SECURITY.md ./
COPY --chown=photoapp:photoapp lib ./lib
COPY --chown=photoapp:photoapp bin/photo_server bin/photo_worker bin/verify_store ./bin/
COPY --chown=photoapp:photoapp start.sh ./start.sh
RUN chmod 0555 start.sh bin/photo_server bin/photo_worker bin/verify_store && mkdir -p /var/lib/photoapp && chown photoapp:photoapp /var/lib/photoapp

USER photoapp
ENV PHOTOAPP_DATA_ROOT=/var/lib/photoapp HOST=0.0.0.0 PORT=3000
EXPOSE 3000
CMD ["./start.sh"]
