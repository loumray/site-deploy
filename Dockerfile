FROM instrumentisto/rsync-ssh:alpine3.17
# Intsall dependencies
RUN apk add bash php nodejs npm
# Add entrypoint and excludes
ADD entrypoint.sh /entrypoint.sh
ADD exclude.txt /exclude.txt
ENTRYPOINT ["/entrypoint.sh"]
