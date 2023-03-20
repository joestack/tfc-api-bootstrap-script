#!/bin/bash
#set -o xtrace

#address=
#organization=
#tfc_token=



version=230316

created=`date +%d.%m.%y-%H:%M:%S`

workdir=$(pwd)
logdir=$workdir/logs

[[ -d $logdir ]] || mkdir $logdir
cd $logdir


check_tfc_token() {
    if [[ ! -e ~/.terraform.d/credentials.tfrc.json ]] ; then
        #echo "No TFC/TFE token found. Please execute 'terraform login'" && exit 1
        exit 1
    else
        tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | jq -r ".credentials.\"${address}\".token ")
        #echo "Using TFC/TFE token from ~/.terraform.d/credentials.tfrc.json"
    fi
}

check_environment() {
    if [[ ! -e $workdir/environment.conf ]] ; then
        #echo "no environment.conf file found in $workdir" && exit 1
        exit 1
    else
        source $workdir/environment.conf
        #echo "environment.conf successfully sourced."
    fi
}


execute_curl() {
    local token="$1"
    local http_method="$2"
    local url="$3"
    local payload="$4"

    case $http_method in
        GET | DELETE)
            local result=$(curl -Ss \
                --header "Authorization: Bearer ${token}" \
                --header "Content-Type: application/vnd.api+json" \
                --request "${http_method}" \
            "${url}")
            ;;
        PATCH | POST)
            local result=$(curl -Ss \
                --header "Authorization: Bearer ${token}" \
                --header "Content-Type: application/vnd.api+json" \
                --request "${http_method}" \
                --data @${payload} \
            "${url}")
            ;;
        *)
            echo "invalid tf_curl request" && exit 1
    esac

    echo "${result}"
}

create_varset_api() {
    local var_set=$1
    
tee $logdir/varset.json > /dev/null <<EOF

{
  "data": {
    "type": "varsets",
    "attributes": {
      "name": "$var_set",
      "description": "To store the initial Vault root token for further programatic workflows",
      "global": true
    },
    "relationships": {
        "vars": {
        "data": [
          {
            "type": "vars",
            "attributes": {
              "key": "created",
              "value": "$created",
              "category": "terraform",
              "sensitive": false,
              "hcl": false
            }
          }
        ]
      }
    }
  }
}
EOF

local result=$(
        execute_curl $tfc_token "POST" \
                "https://${address}/api/v2/organizations/${organization}/varsets" \
                "varset.json"
        )

}

list_varsets_api() {
    local result=$(
        execute_curl $tfc_token "GET" \
                "https://${address}/api/v2/organizations/${organization}/varsets" \
        )
    echo $result | jq  
    #echo $result | jq -r ".data[] | select (.attributes.name == \"foo\") | .id" 
}

find_varset_api() {
    local var_set=$1
    local result=$(
        execute_curl $tfc_token "GET" \
                "https://${address}/api/v2/organizations/${organization}/varsets" \
        )
    echo $result | jq -r ".data[] | select (.attributes.name == \"$var_set\") | .id" 
}

delete_varset_api() {
    local var_set=$1
    var_set_id=`find_varset_api $1`
    #echo $var_set_id
    if [[ $var_set_id == "" ]]
        then
        echo "nothing to delete because varset does not exist"
        else
        echo "Variable Set $var_set deleted"
        local result=$(
          execute_curl $tfc_token "DELETE" \
                "https://${address}/api/v2/varsets/$var_set_id" \
        ) 
    fi 
}


inject_variable_api() {
    pit=`date +%s@%N`

    var_set_id=`find_varset_api $var_set`

    tee $logdir/variable-$pit.json > /dev/null <<EOF

{
  "data": {
    "type": "vars",
    "attributes": {
      "key": "$key",
      "value": "$value",
      "description": "",
      "sensitive": $sensitive,
      "category": "$category",
      "hcl": $hcl
    }
  }
}
EOF


    local result=$(
        execute_curl $tfc_token "POST" \
                "https://${address}/api/v2/varsets/$var_set_id/relationships/vars" \
                "variable-$pit.json"
        )

    echo "$(echo -e ${result} | jq -cM '. | @text ')"
    echo "Adding variable $key in category $category "
}




create_varset() {
    create_varset_api $1
}

list_varsets() {
    list_varsets_api
}

find_varset() {
    find_varset_api $1
}

delete_varset() {
    delete_varset_api $1
}

inject_var_into_varset() {
    echo $1 | while IFS=',' read -r var_set key value category hcl sensitive
    do
        #pit=`date +%s@%N`
        inject_variable_api $var_set $key $value $category $hcl $sensitive
    done 
}


#### MAIN ####

while getopts "c:f:d:i:l" opt
do
    case $opt in
        c) 
            #check_environment
            #check_tfc_token
            create_varset $OPTARG
            ;;
        l)
            #check_environment
            #check_tfc_token
            list_varsets
            ;;
        f)
            #check_environment
            #check_tfc_token
            find_varset $OPTARG
            ;;
        d)
            #check_environment
            #check_tfc_token
            delete_varset $OPTARG
            ;;
        i)
            #check_environment
            #check_tfc_token
            inject_var_into_varset $OPTARG
            ;;
    esac
done

exit 0 

