#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../scripts/utils.sh


image_version=$1
template_file=README-template.md
readme_file=README.md
readme_tmp_file=/tmp/README.md

cp $template_file $readme_file


log "Getting ci result files"
mkdir -p ci
aws s3 cp s3://kafka-docker-playground/ci/ ci/ --recursive


for dir in $(docker run vdesabou/kafka-docker-playground-connect:${image_version} ls /usr/share/confluent-hub-components/)
do
    log "Processing connector $dir"
    test_folders=$(grep ":${dir}:" $template_file | cut -d "(" -f 2 | cut -d ")" -f 1)

    for test_folder in $test_folders
    do
      log "-> test folder $test_folder"
      ci="🤷‍♂️ not tested"
      if [ "$test_folder" != "" ]
      then
        set +e
        last_success_time=""
        for script in $test_folder/*.sh
        do
          script_name=$(basename ${script})
          if [[ "$script_name" = "stop.sh" ]]
          then
            continue
          fi

          # check for ignored scripts in scripts/tests-ignored.txt
          grep "$script_name" ${DIR}/tests-ignored.txt > /dev/null
          if [ $? = 0 ]
          then
            continue
          fi

          # check for scripts containing "repro"
          if [[ "$script_name" == *"repro"* ]]; then
            continue
          fi
          time=""
          if [ "$dir" = "kafka-connect-couchbase" ]
          then
            version="3.4.8"
          else
            version=$(docker run vdesabou/kafka-docker-playground-connect:${image_version} cat /usr/share/confluent-hub-components/${dir}/manifest.json | jq -r '.version')
          fi
          testdir=$(echo "$test_folder" | sed 's/\//-/g')
          last_success_time=$(grep "$dir" ci/${image_version}-${testdir}-${version}-${script_name} | tail -1 | cut -d "|" -f 2)
          log "ci/${image_version}-${testdir}-${version}-${script_name}"
          if [ "$last_success_time" != "" ]
          then
            # now=$(date +%s)
            # elapsed_time=$((now-last_success_time))
            # time="$(displaytime $elapsed_time) ago"
            if [[ "$OSTYPE" == "darwin"* ]]
            then
              time=$(date -r $last_success_time +%Y-%m-%d)
            else
              time=$(date -d @$last_success_time +%Y-%m-%d)
            fi
          fi
        done
        grep "$test_folder" ${DIR}/../.github/workflows/run-regression.yml | grep -v jar > /dev/null
        if [ $? = 0 ]
        then
          if [ "$time" == "" ]
          then
            ci="☠"
            log "☠"
          else
            ci="👍 $time"
            log "👍 $time"
          fi
        fi
        set -e
      fi
    done

    if [ "$dir" = "kafka-connect-couchbase" ]
    then
        sed -e "s|:${dir}:|3.4.8 \| Open Source (Couchbase) \| \| $ci |g" \
            $readme_file > $readme_tmp_file
    else
        version=$(docker run vdesabou/kafka-docker-playground-connect:${image_version} cat /usr/share/confluent-hub-components/${dir}/manifest.json | jq -r '.version')

        license=$(docker run vdesabou/kafka-docker-playground-connect:${image_version} cat /usr/share/confluent-hub-components/${dir}/manifest.json | jq -r '.license[0].name')

        owner=$(docker run vdesabou/kafka-docker-playground-connect:${image_version} cat /usr/share/confluent-hub-components/${dir}/manifest.json | jq -r '.owner.name')

        release_date=$(docker run vdesabou/kafka-docker-playground-connect:${image_version} cat /usr/share/confluent-hub-components/${dir}/manifest.json | jq -r '.release_date')
        if [ "$release_date" = "null" ]
        then
          release_date=""
        fi

        if [ "$license" = "Confluent Software Evaluation License" ]
        then
          type="Confluent Subscription"
        elif [ "$license" = "Apache License 2.0" ] || [ "$license" = "Apache 2.0" ] || [ "$license" = "Apache License, Version 2.0" ] || [ "$license" = "The Apache License, Version 2.0" ]
        then
          type="Open Source ($owner)"
        else
          type="$license"
        fi

        sed -e "s|:${dir}:|${version} \| $type \| $release_date \| $ci |g" \
            $readme_file > $readme_tmp_file
    fi
    cp $readme_tmp_file $readme_file
done