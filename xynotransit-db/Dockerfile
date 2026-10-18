FROM archlinux:base

RUN pacman -Syu --noconfirm --needed postgresql \
 && pacman -Scc --noconfirm \
 && rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

ENV PGHOST=/tmp \
    PGDATA=/var/lib/postgres/data \
    POSTGRES_DB=xynotransit \
    POSTGRES_USER=xynotransit
VOLUME /var/lib/postgres/data

COPY initdb/ /initdb/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER postgres
EXPOSE 5432
ENTRYPOINT ["entrypoint.sh"]
CMD ["postgres"]
