FROM scratch
COPY compose-data.tar /
COPY mysql_backup.sql.tar /
CMD ["/compose-data.tar"]

