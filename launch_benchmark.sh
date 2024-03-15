#!/bin/bash
set -xe


function main {
    # set common info
    source oob-common/common.sh
    init_params $@
    fetch_device_info
    set_environment

    # requirements
    if [ "${DATASET_DIR}" == "" ];then
        set +x
        echo "[ERROR] Please set DATASET_DIR before launch"
        echo "  export DATASET_DIR=/path/to/dataset/dir"
        exit 1
        set -x
    fi
    pip uninstall -y timm
    pip install sympy networkx mpmath
    pip install --no-deps -U timm==0.4.12

    # if multiple use 'xxx,xxx,xxx'
    model_name_list=($(echo "${model_name}" |sed 's/,/ /g'))
    batch_size_list=($(echo "${batch_size}" |sed 's/,/ /g'))

    # generate benchmark
    for model_name in ${model_name_list[@]}
    do
        # cache
        python main.py --eval --data-path $DATASET_DIR --device $device \
            --resume https://dl.fbaipublicfiles.com/deit/deit_base_patch16_224-b5f2ef4d.pth \
            --batch-size 1 \
            --num_iter 3 --num_warmup 1 \
            --precision $precision \
            --channels_last $channels_last \
            ${addtion_options} || true
        #
        for batch_size in ${batch_size_list[@]}
        do
            if [ $batch_size -le 0 ];then
                batch_size=64
            fi
            # clean workspace
            logs_path_clean
            # generate launch script for multiple instance
            if [ "${OOB_USE_LAUNCHER}" == "1" ] && [ "${device}" != "cuda" ];then
                generate_core_launcher
            else
                generate_core
            fi
            # launch
            echo -e "\n\n\n\n Running..."
            cat ${excute_cmd_file} |column -t > ${excute_cmd_file}.tmp
            mv ${excute_cmd_file}.tmp ${excute_cmd_file}
            source ${excute_cmd_file}
            echo -e "Finished.\n\n\n\n"
            # collect launch result
            collect_perf_logs
        done
    done
}

# run
function generate_core {
    # generate multiple instance script
    for(( i=0; i<instance; i++ ))
    do
        real_cores_per_instance=$(echo ${device_array[i]} |awk -F, '{print NF}')
        log_file="${log_dir}/rcpi${real_cores_per_instance}-ins${i}.log"

        # instances
        if [ "${device}" != "cuda" ];then
            OOB_EXEC_HEADER=" numactl -m $(echo ${device_array[i]} |awk -F ';' '{print $2}') "
            OOB_EXEC_HEADER+=" -C $(echo ${device_array[i]} |awk -F ';' '{print $1}') "
        else
            OOB_EXEC_HEADER=" CUDA_VISIBLE_DEVICES=${device_array[i]} "
        fi
        printf " ${OOB_EXEC_HEADER} \
            python main.py --eval --data-path $DATASET_DIR --device $device \
                --resume https://dl.fbaipublicfiles.com/deit/deit_base_patch16_224-b5f2ef4d.pth \
                --batch-size $batch_size \
                --num_iter $num_iter --num_warmup $num_warmup \
                --precision $precision \
                --channels_last $channels_last \
                ${addtion_options} \
        > ${log_file} 2>&1 &  \n" |tee -a ${excute_cmd_file}
        if [ "${numa_nodes_use}" == "0" ];then
            break
        fi
    done
    echo -e "\n wait" >> ${excute_cmd_file}
}

function generate_core_launcher {
    # generate multiple instance script
    for(( i=0; i<instance; i++ ))
    do
        real_cores_per_instance=$(echo ${device_array[i]} |awk -F, '{print NF}')
        log_file="${log_dir}/rcpi${real_cores_per_instance}-ins${i}.log"

        printf "python -m oob-common.launch --enable_jemalloc \
                    --core_list $(echo ${device_array[@]} |sed 's/;.//g') \
                    --log_file_prefix rcpi${real_cores_per_instance} \
                    --log_path ${log_dir} \
                    --ninstances ${#device_array[@]} \
                    --ncore_per_instance ${real_cores_per_instance} \
            main.py --eval --data-path $DATASET_DIR --device $device \
                --resume https://dl.fbaipublicfiles.com/deit/deit_base_patch16_224-b5f2ef4d.pth \
                --batch-size $batch_size \
                --num_iter $num_iter --num_warmup $num_warmup \
                --precision $precision \
                --channels_last $channels_last \
                ${addtion_options} \
        > /dev/null 2>&1 &  \n" |tee -a ${excute_cmd_file}
        break
    done
    echo -e "\n wait" >> ${excute_cmd_file}
}

# download common files
rm -rf oob-common && git clone https://github.com/intel-sandbox/oob-common.git

# Start
main "$@"