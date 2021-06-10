#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.yml"

log "Generating data"
docker exec -i connect bash << EOFCONNECT
mkdir -p /tmp/kafka-connect/examples/
cat <<EOF > /tmp/kafka-connect/examples/playlists.xml
<?xml version="1.0" encoding="UTF-8"?>
<playlists>
    <playlist name="BestOfStarWars">
        <track>
            <title>Duel of the Fates</title>
            <artist>John Williams, London Symphony Orchestra</artist>
            <album>Star Wars: The Phantom Menace (Original Motion Picture Soundtrack)</album>
            <duration>4:14</duration>
        </track>
        <track>
            <title>Star Wars (Main Theme)</title>
            <artist>John Williams, London Symphony Orchestra</artist>
            <album>Star Wars: The Empire Strikes Back (Original Motion Picture Soundtrack)</album>
            <duration>10:52</duration>
        </track>
    </playlist>
</playlists>
EOF
EOFCONNECT


log "Creating XML FilePulse Source connector"
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
          "connector.class":"io.streamthoughts.kafka.connect.filepulse.source.FilePulseSourceConnector",
          "fs.scan.directory.path":"/tmp/kafka-connect/examples/",
          "fs.scan.interval.ms":"10000",
          "fs.scan.filters":"io.streamthoughts.kafka.connect.filepulse.scanner.local.filter.RegexFileListFilter",
          "file.filter.regex.pattern":".*\\.xml$",
          "task.reader.class": "io.streamthoughts.kafka.connect.filepulse.reader.XMLFileInputReader",
          "offset.strategy":"name",
          "topic":"playlists-filepulse-xml-00",
          "internal.kafka.reporter.bootstrap.servers": "broker:9092",
          "internal.kafka.reporter.topic":"connect-file-pulse-status",
          "fs.cleanup.policy.class": "io.streamthoughts.kafka.connect.filepulse.clean.LogCleanupPolicy",
          "tasks.max": 1
          }' \
     http://localhost:8083/connectors/filepulse-source-xml/config | jq .


sleep 5

log "Verify we have received the data in playlists-filepulse-xml-00 topic"
timeout 60 docker exec connect kafka-avro-console-consumer -bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic playlists-filepulse-xml-00 --from-beginning --max-messages 1