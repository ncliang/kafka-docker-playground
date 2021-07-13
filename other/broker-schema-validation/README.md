# Schema Validation on Confluent Server

## Objective

Quickly test [Schema Validation on Confluent Server](https://docs.confluent.io/platform/current/schema-registry/schema-validation.html#sv-on-cs).


## How to run

Simply run:

```
$ ./2way-ssl.sh
```

## Details of what the script is doing

Schema Registry is configured at broker level:

```yml
  broker:
    environment:
      KAFKA_CONFLUENT_SCHEMA_REGISTRY_URL: "https://schema-registry:8085"
      KAFKA_CONFLUENT_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/kafka.client.truststore.jks
      KAFKA_CONFLUENT_SSL_TRUSTSTORE_PASSWORD: confluent
      KAFKA_CONFLUENT_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/kafka.client.keystore.jks
      KAFKA_CONFLUENT_SSL_KEYSTORE_PASSWORD: confluent
      KAFKA_CONFLUENT_SSL_KEY_PASSWORD: confluent

  broker2:
    environment:
      KAFKA_CONFLUENT_SCHEMA_REGISTRY_URL: "https://schema-registry:8085"
      KAFKA_CONFLUENT_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/kafka.client.truststore.jks
      KAFKA_CONFLUENT_SSL_TRUSTSTORE_PASSWORD: confluent
      KAFKA_CONFLUENT_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/kafka.client.keystore.jks
      KAFKA_CONFLUENT_SSL_KEYSTORE_PASSWORD: confluent
      KAFKA_CONFLUENT_SSL_KEY_PASSWORD: confluent
```

Create topic topic-validation:

```bash
$ docker exec broker kafka-topics --bootstrap-server broker:9092 --create --topic topic-validation --partitions 1 --replication-factor 2 --command-config /etc/kafka/secrets/client_without_interceptors_2way_ssl.config --config confluent.key.schema.validation=true --config confluent.value.schema.validation=true
```

Describe topic:

```bash
$ docker exec broker kafka-topics \
   --describe \
   --topic topic-validation \
   --bootstrap-server broker:9092 \
   --command-config /etc/kafka/secrets/client_without_interceptors_2way_ssl.config
```

Register schema:

```bash
$ docker exec connect curl -X POST \
   -H "Content-Type: application/vnd.schemaregistry.v1+json" \
   --cert /etc/kafka/secrets/connect.certificate.pem --key /etc/kafka/secrets/connect.key --tlsv1.2 --cacert /etc/kafka/secrets/snakeoil-ca-1.crt \
   --data '{ "schema": "[ { \"type\":\"record\", \"name\":\"user\", \"fields\": [ {\"name\":\"userid\",\"type\":\"long\"}, {\"name\":\"username\",\"type\":\"string\"} ]} ]" }' \
   https://schema-registry:8085/subjects/topic-validation-value/versions
```

Sending a non-Avro record, it should fail:

```bash
$ docker exec -i connect kafka-console-producer \
     --topic topic-validation \
     --broker-list broker:9092 \
     --producer.config /etc/kafka/secrets/client_without_interceptors_2way_ssl.config << EOF
{"userid":1,"username":"RODRIGUEZ"}
EOF
```

```
[2021-07-13 05:53:27,612] ERROR Error when sending message to topic topic-validation with key: null, value: 35 bytes with error: (org.apache.kafka.clients.producer.internals.ErrorLoggingCallback)
org.apache.kafka.common.InvalidRecordException: One or more records have been rejected
```

Sending a Avro record, it should work:

```bash
$ docker exec -i connect kafka-avro-console-producer \
     --topic topic-validation \
     --broker-list broker:9092 \
     --property schema.registry.url=https://schema-registry:8085 \
     --property value.schema='{"type":"record","name":"user","fields":[{"name":"userid","type":"long"},{"name":"username","type":"string"}]}' \
     --producer.config /etc/kafka/secrets/client_without_interceptors_2way_ssl.config << EOF
{"userid":1,"username":"RODRIGUEZ"}
EOF
```