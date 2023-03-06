#!/bin/bash

set -e

# 修改 k8s 配额
minikube config set cpus 3
minikube config set memory 6144

# 这个脚本用于快速配置 knative 本地开发环境，采用 minikube 作为 k8s 引擎
# 配置 kafka 作为 channel 代替默认的 in-memory channel，kafka 安装采用 strimzi 
# operator 辅助完成
# 使用 kn-quickstart 插件快速配置，同时安装 knative-serving, knative-eventing
# **注意：minikube 默认的的 CPU 和内存配额比较小，需要 3core 6gb 才能跑 kafka，
# 否则会报一些莫名奇秒的错误。
# minikube 需要安装插件 tunnel 来支持 MagicDNS，以便能从本地访问 k8s 服务

# 用 kn quickstart 安装 k8s，在 k8s 上安装 knative-serving, knative-eventing
kn quickstart minikube --install-eventing --install-serving


# 安装 kafka 服务
kubectl create namespace kafka
# 先安装 strimzi operator
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
# 用 strimizi 自动安装 my-cluster kafka 集群, Apply the `Kafka` Cluster CR file
kubectl apply -f https://strimzi.io/examples/latest/kafka/kafka-persistent-single.yaml -n kafka
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka

# 安装 knative kafka 服务
kubectl apply -f https://github.com/knative-sandbox/eventing-kafka-broker/releases/download/knative-v1.9.2/eventing-kafka-controller.yaml
kubectl apply -f https://github.com/knative-sandbox/eventing-kafka-broker/releases/download/knative-v1.9.2/eventing-kafka-channel.yaml
kubectl apply -f https://github.com/knative-sandbox/eventing-kafka-broker/releases/download/knative-v1.9.2/eventing-kafka-broker.yaml
kubectl apply -f https://github.com/knative-sandbox/eventing-kafka-broker/releases/download/knative-v1.9.2/eventing-kafka-sink.yaml

# 开启 kafka 日志
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-config-logging
  namespace: knative-eventing
data:
  config.xml: |
    <configuration>
      <appender name="jsonConsoleAppender" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LogstashEncoder"/>
      </appender>
      <root level="DEBUG">
        <appender-ref ref="jsonConsoleAppender"/>
      </root>
    </configuration>
EOF
kubectl rollout restart deployment -n knative-eventing kafka-broker-receiver
kubectl rollout restart deployment -n knative-eventing kafka-broker-dispatcher
kubectl rollout restart deployment -n knative-eventing kafka-channel-dispatcher
kubectl rollout restart deployment -n knative-eventing kafka-channel-receiver


# 设置 default namespace 的 channel 为 KafkaChannel
# https://knative.dev/docs/eventing/configuration/kafka-channel-configuration/
# https://knative.dev/docs/eventing/channels/channel-types-defaults/
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: default-ch-webhook
  namespace: knative-eventing
data:
  default-ch-config: |
    clusterDefault:
      apiVersion: messaging.knative.dev/v1
      kind: InMemoryChannel
    namespaceDefaults:
      default:
        apiVersion: messaging.knative.dev/v1beta1
        kind: KafkaChannel
        spec:
          numPartitions: 1
          replicationFactor: 1
EOF

# 创建 kafka channel 配置
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-channel
  namespace: knative-eventing
data:
  channel-template-spec: |
    apiVersion: messaging.knative.dev/v1beta1
    kind: KafkaChannel
    spec:
      numPartitions: 1
      replicationFactor: 1
EOF

# 创建以 kafka 为 channel 的 broker
cat <<EOF | kubectl apply -f -
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  annotations:
    eventing.knative.dev/broker.class: MTChannelBasedBroker
  name: kafka-backed-broker
  namespace: default
spec:
  config:
    apiVersion: v1
    kind: ConfigMap
    name: kafka-channel
    namespace: knative-eventing
EOF

# 创建 event source
kn service create cloudevents-source \
--image ruromero/cloudevents-player:latest \
--env BROKER_URL=http://broker-ingress.knative-eventing.svc.cluster.local/default/kafka-backed-broker
kubectl wait service.serving.knative.dev/cloudevents-source --for=condition=Ready --timeout=60s

# 创建 event sink
kn service create cloudevents-sink \
--image ruromero/cloudevents-player:latest \
--env BROKER_URL=http://broker-ingress.knative-eventing.svc.cluster.local/default/kafka-backed-broker
kubectl wait service.serving.knative.dev/cloudevents-sink --for=condition=Ready --timeout=60s

# 创建 trigger 将 broker 消息分发到 event sink
kn trigger create cloudevents-trigger --sink cloudevents-sink --broker kafka-backed-broker
kubectl wait trigger.eventing.knative.dev/cloudevents-trigger --for=condition=Ready --timeout=60s

kn trigger create cloudevents-trigger-kafka --sink cloudevents-sink  --broker kafka-backed-broker --filter type=only-kafka
kubectl wait trigger.eventing.knative.dev/cloudevents-trigger-kafka --for=condition=Ready --timeout=60s

# 对 knative cluster 开启 tunnel
# tunnel creates a route to services deployed with type LoadBalancer and sets their Ingress to their ClusterIP. for a
# detailed example see https://minikube.sigs.k8s.io/docs/tasks/loadbalancer
minikube tunnel --profile knative 2>&1 >/dev/null &

curl -i "$(kubectl get service.serving.knative.dev/cloudevents-source -o=jsonpath='{.status.url}' -n default)/messages" \
        -H "Content-Type: application/json" \
        -H "Ce-Id: 123456789" \
        -H "Ce-Specversion: 1.0" \
        -H "Ce-Type: some-type" \
        -H "Ce-Source: command-line" \
        -d '{"msg":"00000000"}'

curl -i "$(kubectl get service.serving.knative.dev/cloudevents-source -o=jsonpath='{.status.url}' -n default)/messages" \
        -H "Content-Type: application/json" \
        -H "Ce-Id: 123456789" \
        -H "Ce-Specversion: 1.0" \
        -H "Ce-Type: only-kafka" \
        -H "Ce-Source: command-line" \
        -d '{"msg":"only-kafka"}'

# 多个 trigger 不互斥， Ce-Type: only-kafka 会通过上面的两个 trigger 发给 sink，sink 会接收到两条同样的消息
curl "$(kubectl get service.serving.knative.dev/cloudevents-sink -o=jsonpath='{.status.url}' -n default)/messages"
