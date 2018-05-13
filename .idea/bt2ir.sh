#!/usr/bin/env bash
# Simulate IR remote using BT remote

# Bluetooh remote mac address
BT_REMOTE_MAC='08:EB:29:13:35:8C'
BT_HANDLE='0x0030'
KEY_SECOND_ACTION_THRESHOLD=5       # unit 0.1s
KEY_THIRD_ACTION_THRESHOLD=10

# MQTT
MQTT_USER=pi
MQTT_PASS='hhhhhkkkkk'
MQTT_TOPIC='cmnd/bull/IRsend'

# Mi BT remote key define
# K<handle>_<value>=<Action>
declare -A BT_KEYS=(
# key pressed
["K0x0030_0000660000000000"]="K_POWER"
["K0x0030_0000520000000000"]="K_UP"
["K0x0030_0000510000000000"]="K_DOWN"
["K0x0030_0000500000000000"]="K_LEFT"
["K0x0030_00004f0000000000"]="K_RIGHT"
["K0x0030_0000280000000000"]="K_ENTER"
["K0x0030_00003e0000000000"]="K_HOME"
["K0x0030_0000f10000000000"]="K_BACK"
["K0x0030_0000650000000000"]="K_MENU"
["K0x0030_0000800000000000"]="K_VOL_UP"
["K0x0030_0000810000000000"]="K_VOL_DOWN"
# key released
["K0x0030_0000000000000000"]="K_RELEASE"
)

# SONY X9000E IR codes
# <Action>=<IRcode>
declare -A IR_CODES=(
["K_POWER"]="SONY,12,0XA90"               #POWER
["K_UP"]="SONY,12,0X2F0"                  #UP
["K_DOWN"]="SONY,12,0XAF0"                #DOWN
["K_LEFT"]="SONY,12,0X2D0"                #LEFT
["K_RIGHT"]="SONY,12,0XCD0"               #RIGHT
["K_ENTER"]="SONY,12,0XA70"               #ENTER
["K_HOME"]="SONY,12,0X70"                 #HOME
["K_BACK"]="SONY,15,0X62E9"               #BACK
["K_MENU"]="SONY,15,0X7923"               #MENU
["K_VOL_UP"]="SONY,12,0X490"              #VOL_UP
["K_VOL_DOWN"]="SONY,12,0XC90"            #VOL_DOWN

# second/third action at one key
["K_MENU2"]="SONY,15,0X6923"              #SHORTCUT
["K_MENU3"]="SONY,15,0XAE9"               #SUBTITLE
["K_BACK2"]="SONY,15,0X6758"              #DISCOVER
["K_VOL_UP2"]="SONY,12,0X90"              #CH_UP
["K_VOL_DOWN2"]="SONY,12,0X890"           #CH_DOWN
["K_VOL_DOWN3"]="SONY,12,0X290"           #MUTING
)

main(){
    local str
    local handle
    local raw_value
    local value
    local key
    local last_timestamp

    local tmp_fifofile="/tmp/bt2ir_$$.fifo"
    mkfifo $tmp_fifofile
    exec 6<>$tmp_fifofile
    rm $tmp_fifofile

    ( key_listener )&
    while read line; do
    if [[ $line =~ 'Notification' ]]; then
        str="${line#Notification handle = }"
        handle="${str% value*}"
        raw_value="${str#*value: }"
        value="${raw_value// /}"
        key=${BT_KEYS[K${handle}_${value}]}
        echo BT key: $key
        [[ -z $key ]] && continue

        key_second_action=${IR_CODES["${key}2"]}

        # fifo input format: key mode interval interval2
        if [[ $key == K_RELEASE ]]; then
            echo $key >&6
        elif [[ -n $key_second_action ]];then
            echo $key second >&6
        elif [[ $key == K_POWER ]];then
            echo $key single 0.1 >&6
        elif [[ $key == K_HOME ]];then
            echo $key single 0.1 >&6
        elif [[ $key == K_ENTER ]];then
            echo $key single 0.12 0.1 >&6
        else
            echo $key single 0.3 0.12 >&6
        fi
    fi
    done < <(gatttool -b $BT_REMOTE_MAC --char-read -a $BT_HANDLE --listen)
}

key_listener(){
    local timeout=
    while true; do
        if [[ -n $timeout ]];then
            read -t $timeout -u6 key mode interval interval2
        else
            read -u6 key mode interval interval2
        fi
        local err_code=$?
        timestamp=$(date +%s%N)
        if (($err_code == 0)); then
            echo Action: $key $mode $interval $interval2
            if [[ $mode == single ]]; then
                parse_action ${key:-$pre_key}
                timeout=$interval
                interval=${interval2:-$interval}
            elif [[ $mode == second ]]; then
                timeout=
            elif [[ $key == K_RELEASE ]]; then
                if [[ $pre_mode == second ]]; then
                    # unit 0.1s
                    interval=$(( (timestamp - last_timestamp)/100000000 ))
                    key_second_action="${IR_CODES["${pre_key}2"]}"
                    key_third_action="${IR_CODES["${pre_key}3"]}"

                    if (( interval > KEY_THIRD_ACTION_THRESHOLD )) && [[ -n $key_third_action ]]; then
                        parse_action ${pre_key}3
                    elif (( interval > KEY_SECOND_ACTION_THRESHOLD )); then
                        parse_action ${pre_key}2
                    else
                        parse_action ${pre_key}
                    fi
                fi

                timeout=
            fi
            last_timestamp=$(date +%s%N)
        else
            parse_action $pre_key
            timeout=$pre_interval
        fi
        pre_key=${key:-$pre_key}
        pre_mode=${mode:-$pre_mode}
        pre_interval=${interval:-$pre_interval}
    done
}

parse_action(){
    local action=$1
    [[ -z $action ]] && return

    local ir_info=${IR_CODES[$action]}
    if [[ -z $ir_info ]];then
        echo No IR command: $action
        return
    fi
    (
        IFS=,
        info_array=($ir_info)
        protocol=${info_array[0]}
        bits=${info_array[1]}
        data=${info_array[2]}

        echo Send IR command: $action
        send_ir_command $protocol $bits $data
    )&
}

send_ir_command(){
    local protocol=$1
    local bits=$2
    local data=$(($3))  # Hex to Dec
    local msg="{\"Protocol\":\"$protocol\",\"Bits\":$bits,\"Data\":\"$data\"}"
    mosquitto_pub -u $MQTT_USER -P $MQTT_PASS -t $MQTT_TOPIC -m "$msg"
}

main