#!/bin/bash

sudo ip netns add ue1
sudo ip netns list


sudo pkill srsepc && echo "srsepc end successfully"
sudo pkill srsenb && echo "srsenb end successfully"

sleep 5

(sudo nohup  /home/caizr/GitProj/srsRAN_4G/build/srsepc/src/srsepc > /dev/null 2>&1 &) && (echo "start epc successfully") 

(sudo nohup /home/caizr/GitProj/srsRAN_4G/build/srsenb/src/srsenb --rf.device_name=zmq --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=23.04e6" > /dev/null 2>&1 & ) && (echo "start enb successfully") 


